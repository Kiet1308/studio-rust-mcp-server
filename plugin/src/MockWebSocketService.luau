local HttpService = game:GetService("HttpService")

local MockWebSocketClient = {}
MockWebSocketClient.__index = MockWebSocketClient

local EnumWebSocketState = {
	Connecting = "Connecting",
	Open = "Open",
	Closing = "Closing",
	Closed = "Closed",
}

local CloseableStates = {
	[EnumWebSocketState.Connecting] = true,
	[EnumWebSocketState.Open] = true,
}

local POLL_WAIT_TIME = 1
local SEND_ATTEMPTS = 3
local SEND_RETRY_DELAY = 1

export type MockWebSocketClient = {
	Send: (self: MockWebSocketClient, data: any) -> boolean,
	Ack: (self: MockWebSocketClient, id: string) -> (),
	Close: (self: MockWebSocketClient) -> (),
	SetReceiveEndpoint: (self: MockWebSocketClient, endpoint: string) -> (),
	SetSendEndpoint: (self: MockWebSocketClient, endpoint: string) -> (),
	SetAckEndpoint: (self: MockWebSocketClient, endpoint: string) -> (),
	Opened: RBXScriptSignal,
	Closed: RBXScriptSignal,
	MessageReceived: RBXScriptSignal,
	ConnectionState: typeof(EnumWebSocketState.Connecting),
}

type MockWebSocketClientPrivate = MockWebSocketClient & {
	new: (uri: string) -> MockWebSocketClient,
	_OpenImpl: (self: MockWebSocketClient) -> (),
	_uri: string,
	_receiveEndpoint: string,
	_sendEndpoint: string,
	_ackEndpoint: string,
	_pollTask: thread?,
	_OpenedEvent: BindableEvent,
	_ClosedEvent: BindableEvent,
	_MessageReceivedEvent: BindableEvent,
}

function MockWebSocketClient.new(uri: string): MockWebSocketClient
	local self: MockWebSocketClientPrivate = setmetatable({}, MockWebSocketClient) :: any

	self._uri = uri
	self._receiveEndpoint = ""
	self._sendEndpoint = ""
	self._ackEndpoint = ""
	self._pollTask = nil :: thread?

	self._OpenedEvent = Instance.new("BindableEvent")
	self.Opened = self._OpenedEvent.Event

	self._ClosedEvent = Instance.new("BindableEvent")
	self.Closed = self._ClosedEvent.Event

	self._MessageReceivedEvent = Instance.new("BindableEvent")
	self.MessageReceived = self._MessageReceivedEvent.Event

	self.ConnectionState = EnumWebSocketState.Connecting

	task.defer(self._OpenImpl, self)

	return self
end

local function doRequest(url: string, method: "GET" | "POST", body: any)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = method,
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = if body then HttpService:JSONEncode(body) else nil,
			Compress = Enum.HttpCompression.None,
		})
	end)

	return if ok then response else nil
end

function MockWebSocketClient._OpenImpl(self: MockWebSocketClientPrivate)
	assert(self.ConnectionState == EnumWebSocketState.Connecting, "WebSocket is not in the Connecting state")

	self.ConnectionState = EnumWebSocketState.Open
	self._OpenedEvent:Fire()

	self._pollTask = task.spawn(function()
		while self.ConnectionState == EnumWebSocketState.Open do
			local response = doRequest(self._uri .. self._receiveEndpoint, "GET")

			-- The client may have been closed while the request was in flight.
			if self.ConnectionState ~= EnumWebSocketState.Open then
				break
			end

			if response then
				if response.StatusCode == 200 and response.Success then
					self._MessageReceivedEvent:Fire(response.Body)
					continue
				elseif response.StatusCode == 423 then
					-- The long poll expired with nothing to do; poll again.
					continue
				end
			end

			task.wait(POLL_WAIT_TIME)
		end
	end)
end

function MockWebSocketClient.Send(self: MockWebSocketClientPrivate, data: any): boolean
	for attempt = 1, SEND_ATTEMPTS do
		local response = doRequest(self._uri .. self._sendEndpoint, "POST", data)
		if response and response.Success then
			return true
		end
		-- Client errors (4xx) will not improve with a retry.
		if response and response.StatusCode < 500 then
			return false
		end
		if attempt < SEND_ATTEMPTS then
			task.wait(SEND_RETRY_DELAY)
		end
	end
	return false
end

function MockWebSocketClient.Ack(self: MockWebSocketClientPrivate, id: string)
	-- Best effort: if the ack is lost the server redelivers the request and
	-- the plugin deduplicates it by id.
	doRequest(self._uri .. self._ackEndpoint, "POST", { id = id })
end

function MockWebSocketClient.Close(self: MockWebSocketClientPrivate)
	if CloseableStates[self.ConnectionState] then
		self.ConnectionState = EnumWebSocketState.Closing

		local pollTask = self._pollTask
		self._pollTask = nil :: any
		if pollTask and coroutine.status(pollTask) == "suspended" then
			-- Cancelling may fail while the thread is yielded inside a pcall;
			-- the poll loop also exits on its own once ConnectionState leaves
			-- Open, so this is best effort.
			pcall(task.cancel, pollTask)
		end

		self.ConnectionState = EnumWebSocketState.Closed
		self._ClosedEvent:Fire()
	end
end

-- START DEVIATION: These methods are not present in the real WebSocketClient instance
function MockWebSocketClient.SetReceiveEndpoint(self: MockWebSocketClientPrivate, endpoint: string)
	self._receiveEndpoint = endpoint
end

function MockWebSocketClient.SetSendEndpoint(self: MockWebSocketClientPrivate, endpoint: string)
	self._sendEndpoint = endpoint
end

function MockWebSocketClient.SetAckEndpoint(self: MockWebSocketClientPrivate, endpoint: string)
	self._ackEndpoint = endpoint
end
-- END DEVIATION

local MockWebSocketService = {}
MockWebSocketService.__index = MockWebSocketService

type MockWebSocketService = {
	CreateClient: (self: MockWebSocketService, uri: string) -> MockWebSocketClient,
}

function MockWebSocketService.CreateClient(_: MockWebSocketService, uri: string)
	return MockWebSocketClient.new(uri)
end

return MockWebSocketService
