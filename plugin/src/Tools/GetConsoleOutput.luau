local Main = script:FindFirstAncestor("MCPStudioPlugin")
local ConsoleOutput = require(Main.Utils.ConsoleOutput)
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")

local VALID_LEVELS = { output = true, info = true, warning = true, error = true }

local function handleGetConsoleOutput(args: Types.GetConsoleOutputArgs): string?
	local level: string? = nil
	if args.level ~= nil and args.level ~= "" and args.level ~= "all" then
		if not VALID_LEVELS[args.level] then
			error(
				string.format(
					"Invalid level %q: must be output, info, warning, error, or all",
					tostring(args.level)
				)
			)
		end
		level = args.level
	end
	local limit = math.clamp(if type(args.limit) == "number" then args.limit else 100, 1, 500)
	local sinceSeq = if type(args.since_seq) == "number" then args.since_seq else nil

	local entries, dropped = ConsoleOutput.collect(ConsoleOutput.entries, sinceSeq, level, limit)
	return HttpService:JSONEncode({
		entries = entries,
		last_seq = ConsoleOutput.lastSeq,
		dropped = dropped,
	})
end

return handleGetConsoleOutput :: Types.ToolFunction
