--[[
	Polls a Luau condition until it returns a truthy value or the timeout
	expires. The backbone of stable end-to-end tests: wait for a character to
	spawn, a UI to appear, a value to change — instead of sleeping blindly.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local LuauCompile = require(Main.Utils.LuauCompile)
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")

local MAX_TIMEOUT_SECONDS = 600

local function handleWaitFor(args: Types.WaitForArgs): string?
	if type(args.condition) ~= "string" or args.condition == "" then
		error("Missing condition in WaitFor: pass Luau code whose first return value is checked for truthiness")
	end

	local timeout = math.clamp(if type(args.timeout) == "number" then args.timeout else 30, 0.1, MAX_TIMEOUT_SECONDS)
	local pollInterval = math.clamp(if type(args.poll_interval) == "number" then args.poll_interval else 0.25, 0.05, 10)

	local chunk = LuauCompile.compile(args.condition, script)

	local startClock = os.clock()
	local lastError: string? = nil
	local satisfied = false
	local finalValue: any = nil
	local checks = 0

	while true do
		checks += 1
		local ok, value = pcall(chunk)
		if ok then
			lastError = nil
			if value then
				satisfied = true
				finalValue = value
				break
			end
		else
			lastError = tostring(value)
		end
		if os.clock() - startClock >= timeout then
			break
		end
		task.wait(pollInterval)
	end

	return HttpService:JSONEncode({
		satisfied = satisfied,
		elapsed = math.round((os.clock() - startClock) * 100) / 100,
		checks = checks,
		value = if finalValue ~= nil then tostring(finalValue) else nil,
		last_error = lastError,
	})
end

return handleWaitFor :: Types.ToolFunction
