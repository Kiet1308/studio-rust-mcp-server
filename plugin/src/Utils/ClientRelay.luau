--[[
	Relays MCP commands to the play-mode client DataModel.

	HttpService is hard blocked on the play client ("Http requests can only be
	executed by game server"), so the client cannot poll the MCP server itself.
	Instead the server plugin instance polls /request?role=client on the
	client's behalf and shuttles commands and responses through a RemoteEvent,
	which does cross the client/server boundary (verified to work between the
	two plugin VMs).

	Payloads are chunked because RemoteEvent arguments have size limits well
	below a screenshot or UI-tree response.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local MockWebSocketService = require(Main.MockWebSocketService)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_NAME = "MCP_CLIENT_RELAY"
local CHUNK_SIZE = 50_000
-- How long the server waits for a player before deciding this session has no
-- client (run mode). The client never polls, so commands addressed to it fast
-- fail on the Rust side once nothing polls ?role=client.
local PLAYER_WAIT_SECONDS = 30
local REMOTE_WAIT_SECONDS = 60

local ClientRelay = {}

type Envelope = {
	id: string,
	kind: "cmd" | "resp",
	seq: number,
	total: number,
	data: string,
}

local function sendChunked(fire: (Envelope) -> (), kind: "cmd" | "resp", id: string, data: string)
	local total = math.max(1, math.ceil(#data / CHUNK_SIZE))
	for seq = 1, total do
		fire({
			id = id,
			kind = kind,
			seq = seq,
			total = total,
			data = string.sub(data, (seq - 1) * CHUNK_SIZE + 1, seq * CHUNK_SIZE),
		})
	end
end

-- Returns a handler that accumulates chunked envelopes of one kind and calls
-- onComplete(id, fullPayload) once every chunk of a message has arrived.
-- RemoteEvent delivery is ordered per remote, so out-of-order chunks are not a
-- concern, but the handler tolerates them anyway.
local function makeReassembler(kind: string, onComplete: (string, string) -> ())
	local pending: { [string]: { parts: { string }, count: number, total: number } } = {}
	return function(envelope: any)
		if
			type(envelope) ~= "table"
			or envelope.kind ~= kind
			or type(envelope.id) ~= "string"
			or type(envelope.seq) ~= "number"
			or type(envelope.total) ~= "number"
			or type(envelope.data) ~= "string"
		then
			return
		end
		local entry = pending[envelope.id]
		if not entry then
			entry = { parts = {}, count = 0, total = envelope.total }
			pending[envelope.id] = entry
		end
		if entry.parts[envelope.seq] == nil then
			entry.parts[envelope.seq] = envelope.data
			entry.count += 1
		end
		if entry.count >= entry.total then
			pending[envelope.id] = nil
			onComplete(envelope.id, table.concat(entry.parts))
		end
	end
end

-- Runs in the play-mode server DataModel: polls the MCP server for
-- client-targeted commands and relays them through the RemoteEvent.
function ClientRelay.startServer(uri: string, instanceId: string)
	local remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE_NAME
	remote.Parent = ReplicatedStorage

	task.spawn(function()
		-- The poll client is created only once the relay is fully wired; until
		-- then no command can be received (and therefore none can be lost).
		local pollClient: MockWebSocketService.MockWebSocketClient? = nil

		local clientReady = false
		local reassembleResponse = makeReassembler("resp", function(_id, payload)
			local ok, body = pcall(function()
				return HttpService:JSONDecode(payload)
			end)
			if not ok or type(body) ~= "table" or not pollClient then
				return
			end
			local sender = pollClient
			task.spawn(function()
				sender:Send(body)
			end)
		end)
		-- OnServerEvent prepends the sending Player to the arguments.
		remote.OnServerEvent:Connect(function(_player, envelope)
			if type(envelope) == "table" and envelope.kind == "ready" then
				clientReady = true
				return
			end
			reassembleResponse(envelope)
		end)

		-- Run mode has no client; only start polling for client commands once a
		-- player actually exists.
		local playerDeadline = os.clock() + PLAYER_WAIT_SECONDS
		while #Players:GetPlayers() == 0 do
			if os.clock() > playerDeadline then
				return
			end
			task.wait(0.25)
		end

		-- Commands delivered before the client connects its listener would be
		-- lost (the server acks them on receipt, so the MCP server will not
		-- redeliver). Wait for the client's ready signal before polling.
		local readyDeadline = os.clock() + REMOTE_WAIT_SECONDS
		while not clientReady and os.clock() < readyDeadline do
			task.wait(0.1)
		end
		if not clientReady then
			return
		end

		local client = MockWebSocketService:CreateClient(uri)
		client:SetReceiveEndpoint("/request?role=client&instance=" .. HttpService:UrlEncode(instanceId))
		client:SetSendEndpoint("/response")
		client:SetAckEndpoint("/ack")
		pollClient = client

		client.MessageReceived:Connect(function(message)
			local ok, body = pcall(function()
				return HttpService:JSONDecode(message)
			end)
			if not ok or type(body) ~= "table" or type(body.id) ~= "string" then
				return
			end
			-- Ack from the server: the client cannot reach the MCP server, and
			-- an early ack stops redelivery while the command crosses the relay.
			task.spawn(function()
				client:Ack(body.id)
			end)
			sendChunked(function(envelope)
				remote:FireAllClients(envelope)
			end, "cmd", body.id, message)
		end)
	end)
end

-- Runs in the play-mode client DataModel: executes relayed commands with the
-- same guarded runner used for HTTP-delivered commands and returns results
-- through the RemoteEvent.
function ClientRelay.startClient(runTool: (any) -> (boolean, string))
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild(REMOTE_NAME, REMOTE_WAIT_SECONDS)
		if not remote or not remote:IsA("RemoteEvent") then
			return
		end

		local requestQueue: { any } = {}
		local seenRequests: { [string]: boolean } = {}

		task.spawn(function()
			while true do
				local body = table.remove(requestQueue, 1)
				if body then
					local success, response = runTool(body.args)
					local payload = HttpService:JSONEncode({
						id = body.id,
						success = success,
						response = response,
					})
					sendChunked(function(envelope)
						remote:FireServer(envelope)
					end, "resp", body.id, payload)
				else
					task.wait()
				end
			end
		end)

		remote.OnClientEvent:Connect(makeReassembler("cmd", function(_id, payload)
			local ok, body = pcall(function()
				return HttpService:JSONDecode(payload)
			end)
			if not ok or type(body) ~= "table" or type(body.id) ~= "string" or type(body.args) ~= "table" then
				return
			end
			if seenRequests[body.id] then
				return
			end
			seenRequests[body.id] = true
			table.insert(requestQueue, body)
		end))

		-- Listener is connected; tell the server relay it is safe to start
		-- accepting commands on the client's behalf.
		remote:FireServer({ kind = "ready" })
	end)
end

return ClientRelay
