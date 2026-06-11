local Main = script:FindFirstAncestor("MCPStudioPlugin")
local ClientRelay = require(Main.Utils.ClientRelay)
local ConsoleOutput = require(Main.Utils.ConsoleOutput)
local DataModelType = require(Main.Utils.DataModelType)
local GameStopUtil = require(Main.Utils.GameStopUtil)
local GlobalVariables = require(Main.Utils.GlobalVariables)
local InstanceIdentity = require(Main.Utils.InstanceIdentity)
local MockWebSocketService = require(Main.MockWebSocketService)
local PluginUtils = require(Main.Utils.PluginUtils)
local ToolDispatcher = require(Main.Utils.ToolDispatcher)
local Types = require(Main.Types)

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local StudioService = game:GetService("StudioService")

local URI = "http://localhost:44755"
local RECEIVE_ENDPOINT = "/request"
local SEND_ENDPOINT = "/response"
local ACK_ENDPOINT = "/ack"
local PLUGIN_DISABLED_SETTING_KEY = "Disabled-MCP-plugin-setting"
-- How many handled request ids are remembered to deduplicate redeliveries.
local MAX_TRACKED_REQUESTS = 200
-- Mirrors execution_timeout() in src/rbx_studio_server.rs (300s default;
-- play-mode timeout + 60s grace) with a margin so the plugin aborts a stuck
-- tool and reports the failure before the server gives up on the request.
local DEFAULT_TOOL_TIMEOUT = 270
local PLAY_MODE_TIMEOUT_GRACE = 45

local PluginMain = {}

-- Shared bootstrap for every DataModel the plugin runs in. The entry scripts
-- (Main.server.luau for edit/server, MainClient.client.luau for the play-mode
-- client) decide whether their context applies and then call run().
function PluginMain.run(plugin: Plugin)
	PluginUtils.plugin = plugin

	local datamodelType = DataModelType.getDataModelType()

	if datamodelType == "Server" then
		task.spawn(GameStopUtil.monitorForStopPlay)
	end

	if datamodelType == "Unknown" then
		return
	end

	-- Every DataModel (edit, play server, play client) keeps its own connection
	-- to the MCP server, tagged with its role, so commands can be routed to a
	-- specific context (e.g. input simulation on the client, code on the server).
	local role = string.lower(datamodelType)
	local isEdit = datamodelType == "Edit"

	-- Identifies which Studio window this DataModel belongs to, so multiple
	-- Studio windows can be open at once without stealing each other's
	-- commands. Play DataModels adopt the id of the edit window that started
	-- them (see InstanceIdentity). Two windows with the same unsaved place
	-- name collide (documented limitation).
	local instanceId = if isEdit
		then InstanceIdentity.computeRaw()
		else InstanceIdentity.adoptForPlay(InstanceIdentity.computeRaw())
	GlobalVariables.instanceId = instanceId
	local pollQuery = "?role=" .. role .. "&instance=" .. HttpService:UrlEncode(instanceId)

	local connMessageOut = ConsoleOutput.startListener()

	local old_warn = warn
	local function log(...)
		if false then
			old_warn(...)
		end
	end

	local function toolCallHandler(args: Types.ToolArgs): string
		local toolName = next(args)
		if not toolName then
			error("No tool name found in request")
		end

		local toolArgs = args[toolName]
		if not toolArgs or type(toolArgs) ~= "table" then
			error("Invalid tool args found for tool name: " .. toolName)
		end

		local success, response = pcall(ToolDispatcher.dispatchTool, toolName, toolArgs)
		if success then
			return response or ""
		end
		error("Error handling request: " .. tostring(response))
	end

	local function executionTimeout(args: Types.ToolArgs): number
		local toolName = next(args)
		if toolName == "RunScriptInPlayMode" then
			local toolArgs = args[toolName] :: any
			local timeout = if type(toolArgs) == "table" and type(toolArgs.timeout) == "number"
				then toolArgs.timeout
				else 100
			return timeout + PLAY_MODE_TIMEOUT_GRACE
		end
		if toolName == "WaitFor" then
			local toolArgs = args[toolName] :: any
			local timeout = if type(toolArgs) == "table" and type(toolArgs.timeout) == "number"
				then math.clamp(toolArgs.timeout, 0.1, 600)
				else 30
			return timeout + PLAY_MODE_TIMEOUT_GRACE
		end
		if toolName == "InputSequence" then
			-- Mirrors execution_timeout() in src/rbx_studio_server.rs: one
			-- second of overhead per step plus its waits and holds.
			local toolArgs = args[toolName] :: any
			local total = 0
			if type(toolArgs) == "table" and type(toolArgs.steps) == "table" then
				for _, step in toolArgs.steps do
					if type(step) == "table" then
						total += 1
						if type(step.seconds) == "number" then
							total += math.clamp(step.seconds, 0, 10)
						end
						if type(step.duration) == "number" then
							total += math.clamp(step.duration, 0, 30)
						end
					end
				end
			end
			return total + PLAY_MODE_TIMEOUT_GRACE
		end
		return DEFAULT_TOOL_TIMEOUT
	end

	-- Runs one tool call on its own thread and abandons it if it exceeds its
	-- deadline. Without this, code that yields forever (e.g. WaitForChild on an
	-- instance that never appears) wedges the worker thread and no later request
	-- ever executes until Studio restarts.
	local function runToolGuarded(args: Types.ToolArgs): (boolean, string)
		local doneEvent = Instance.new("BindableEvent")
		local finished = false
		local success: boolean? = nil
		local response = ""

		-- Undo recording only exists in the edit DataModel.
		local recording = if isEdit then ChangeHistoryService:TryBeginRecording("StudioMCP") else nil

		local runner = task.spawn(function()
			local ok, result = pcall(toolCallHandler, args)
			success = ok
			response = if ok then result or "" else tostring(result)
			if not finished then
				finished = true
				doneEvent:Fire()
			end
		end)

		local timeout = executionTimeout(args)
		local watchdog = task.delay(timeout, function()
			if not finished then
				finished = true
				doneEvent:Fire()
			end
		end)

		if not finished then
			doneEvent.Event:Wait()
		end

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		pcall(task.cancel, watchdog)
		doneEvent:Destroy()

		if success ~= nil then
			return success :: boolean, response
		end

		-- Timed out: abandon the stuck thread and reset global state so the next
		-- request starts clean. Only the edit DataModel manages the play session;
		-- a stuck tool on a play DataModel must not kill the session it runs in.
		pcall(task.cancel, runner)
		if isEdit and GlobalVariables.studioMode ~= "stop" then
			pcall(GameStopUtil.stopPlay)
			GlobalVariables.studioMode = "stop"
		end

		local toolName = next(args)
		return false, string.format(
			"%s timed out after %d seconds and was aborted by the MCP plugin."
				.. " The code most likely yielded forever (for example :WaitForChild() on an"
				.. " instance that never appears, or waiting on an event that never fires)."
				.. " Use :WaitForChild(name, timeoutInSeconds) or :FindFirstChild() instead."
				.. " The plugin is still running and ready for new requests.",
			tostring(toolName or "Tool"),
			timeout
		)
	end

	local function connectWebSocket()
		local client = MockWebSocketService:CreateClient(URI)
		client:SetReceiveEndpoint(RECEIVE_ENDPOINT .. pollQuery)
		client:SetSendEndpoint(SEND_ENDPOINT)
		client:SetAckEndpoint(ACK_ENDPOINT)

		client.Opened:Once(function()
			log("[MCP] Connection opened")
		end)

		local closed = false
		client.Closed:Once(function()
			closed = true
			log("[MCP] Connection closed")
		end)

		-- Requests wait here while a tool is still running; a dedicated worker
		-- thread executes them one at a time so the poll loop is free to keep a
		-- long poll open at the server even during long tool runs.
		local requestQueue = {}
		-- Remembers request ids so a redelivery (the server resends when an ack
		-- is lost) is answered from the stored result instead of running twice.
		local seenRequests = {}
		local seenOrder = {}

		local function sendResult(id: string, success: boolean, response: string)
			log("[MCP] Sending response:", response)
			if not client:Send({ id = id, success = success, response = response }) then
				log("[MCP] Failed to deliver response for request", id)
			end
		end

		task.spawn(function()
			while not closed do
				local body = table.remove(requestQueue, 1)
				if body then
					local success, responseStr = runToolGuarded(body.args)
					local seen = seenRequests[body.id]
					if seen then
						seen.done = true
						seen.success = success
						seen.response = responseStr
					end
					sendResult(body.id, success, responseStr)
					log("[MCP] Successfully handled request")
				else
					task.wait()
				end
			end
		end)

		client.MessageReceived:Connect(function(message)
			log("[MCP] Message received")

			local ok, body = pcall(function()
				return HttpService:JSONDecode(message)
			end)
			if not ok or type(body) ~= "table" or type(body.id) ~= "string" or type(body.args) ~= "table" then
				log("[MCP] Invalid message received")
				return
			end

			-- Acknowledge receipt right away so the server stops redelivering.
			task.spawn(function()
				client:Ack(body.id)
			end)

			local seen = seenRequests[body.id]
			if seen then
				if seen.done then
					task.spawn(sendResult, body.id, seen.success, seen.response)
				end
				return
			end

			seenRequests[body.id] = { done = false }
			table.insert(seenOrder, body.id)
			if #seenOrder > MAX_TRACKED_REQUESTS then
				local oldest = table.remove(seenOrder, 1)
				seenRequests[oldest] = nil
			end

			table.insert(requestQueue, body)
		end)

		return client
	end

	local function getButtonImage()
		local ok, response = pcall(function()
			return StudioService:GetClassIcon("PackageLink").Image
		end)
		return ok and response or "rbxasset://textures/ui/GuiImagePlaceholder.png"
	end

	local currentClient: MockWebSocketService.MockWebSocketClient?

	plugin.Unloading:Connect(function()
		connMessageOut:Disconnect()
		if currentClient then
			currentClient:Close()
			currentClient = nil
		end
	end)

	-- The disabled setting is shared across DataModels, so toggling the button
	-- in edit mode also keeps play-mode instances from connecting.
	if not plugin:GetSetting(PLUGIN_DISABLED_SETTING_KEY) then
		if datamodelType == "Client" then
			-- HttpService is blocked on the play client; commands arrive through
			-- the server's relay instead of an HTTP connection of our own.
			ClientRelay.startClient(runToolGuarded)
			return
		end
		currentClient = connectWebSocket()
		if datamodelType == "Server" then
			ClientRelay.startServer(URI, instanceId)
		end
		if isEdit then
			print("MCP v3 (play-test) loaded")
		end
	end

	if isEdit then
		local toolbar = plugin:CreateToolbar("MCP")
		local toggleButton = toolbar:CreateButton("Toggle MCP", "Toggle connection to the server", getButtonImage())
		toggleButton.ClickableWhenViewportHidden = true

		toggleButton:SetActive(currentClient ~= nil)

		toggleButton.Click:Connect(function()
			if not currentClient then
				currentClient = connectWebSocket()
				print("MCP v3 (play-test) loaded")
			else
				currentClient:Close()
				currentClient = nil
				print("The MCP Studio plugin is stopped.")
			end
			toggleButton:SetActive(currentClient ~= nil)
			plugin:SetSetting(PLUGIN_DISABLED_SETTING_KEY, currentClient == nil)
		end)
	end
end

return PluginMain
