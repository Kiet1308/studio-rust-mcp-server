--[[
	Returns script errors captured through ScriptContext.Error — unlike the
	console stream, these carry the full stack trace and the erroring
	script's path, which is what a failing end-to-end test needs.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local ConsoleOutput = require(Main.Utils.ConsoleOutput)
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")

local function handleGetErrors(args: Types.GetErrorsArgs): string?
	local limit = math.clamp(if type(args.limit) == "number" then args.limit else 50, 1, 200)
	local sinceSeq = if type(args.since_seq) == "number" then args.since_seq else nil

	local errors, dropped = ConsoleOutput.collect(ConsoleOutput.errors, sinceSeq, nil, limit)
	return HttpService:JSONEncode({
		errors = errors,
		count = #errors,
		last_seq = ConsoleOutput.lastSeq,
		dropped = dropped,
	})
end

return handleGetErrors :: Types.ToolFunction
