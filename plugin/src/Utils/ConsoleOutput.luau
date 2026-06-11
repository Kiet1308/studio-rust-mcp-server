--[[
	Captures console output and script errors for the DataModel this plugin
	instance runs in.

	Entries live in a ring buffer (newest kept) with monotonically increasing
	sequence numbers, so callers can read incrementally with since_seq instead
	of re-reading everything. Script errors are captured separately through
	ScriptContext.Error, which carries the stack trace that LogService drops.
]]

local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")

local MAX_ENTRIES = 2000
local MAX_ERRORS = 300
-- Trim in batches so the O(n) front-removal cost is paid rarely.
local TRIM_BATCH = 200

local MESSAGE_TYPE_MAP: { [Enum.MessageType]: string } = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

local ConsoleOutput = {
	entries = {} :: { any },
	errors = {} :: { any },
	lastSeq = 0,
}

local function trim(list: { any }, maxEntries: number)
	if #list > maxEntries then
		for _ = 1, TRIM_BATCH do
			table.remove(list, 1)
		end
	end
end

function ConsoleOutput.startListener()
	local connMessageOut = LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
		ConsoleOutput.lastSeq += 1
		table.insert(ConsoleOutput.entries, {
			seq = ConsoleOutput.lastSeq,
			ts = os.time(),
			level = MESSAGE_TYPE_MAP[messageType] or "output",
			message = message,
		})
		trim(ConsoleOutput.entries, MAX_ENTRIES)
	end)

	local connError = ScriptContext.Error:Connect(function(message: string, stackTrace: string, source: Instance?)
		ConsoleOutput.lastSeq += 1
		table.insert(ConsoleOutput.errors, {
			seq = ConsoleOutput.lastSeq,
			ts = os.time(),
			message = message,
			stack = stackTrace,
			script_path = if source then source:GetFullName() else nil,
		})
		trim(ConsoleOutput.errors, MAX_ERRORS)
	end)

	return {
		Disconnect = function()
			connMessageOut:Disconnect()
			connError:Disconnect()
		end,
	}
end

-- Entries newer than sinceSeq matching level, oldest-first, at most limit
-- (taken from the tail so the newest survive). Returns the matches and how
-- many matching entries the limit cut off.
function ConsoleOutput.collect(list: { any }, sinceSeq: number?, level: string?, limit: number): ({ any }, number)
	local matched = {}
	for _, entry in list do
		if sinceSeq and entry.seq <= sinceSeq then
			continue
		end
		if level and entry.level and entry.level ~= level then
			continue
		end
		table.insert(matched, entry)
	end
	local dropped = math.max(0, #matched - limit)
	local result = if dropped > 0 then table.move(matched, dropped + 1, #matched, 1, {}) else matched
	return result, dropped
end

return ConsoleOutput
