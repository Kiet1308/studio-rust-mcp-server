--[[
	Runs a list of input steps in one round trip, so combos that depend on
	timing (double clicks, hold-and-click, drag-then-release patterns) are
	not broken up by per-call latency. Stops at the first failing step and
	reports how far it got.

	Each step is translated to the matching single tool's arguments, so the
	behavior is identical to calling that tool — `mode` carries what the
	single tools call `action` (click/down/up, tap/press/release).
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local ClickObject = require(Main.Tools.ClickObject)
local ClickUi = require(Main.Tools.ClickUi)
local MouseDrag = require(Main.Tools.MouseDrag)
local MouseMove = require(Main.Tools.MouseMove)
local SendKey = require(Main.Tools.SendKey)
local SendText = require(Main.Tools.SendText)
local Types = require(Main.Types)
local VirtualInput = require(Main.Utils.VirtualInput)

local HttpService = game:GetService("HttpService")

local MAX_STEPS = 50
local MAX_WAIT = 10
local MAX_TOTAL_SECONDS = 120

local function buildStep(step: { [string]: any }): (((any) -> string?)?, any)
	local action = step.action
	if action == "click" then
		return ClickUi,
			{ path = step.path, x = step.x, y = step.y, button = step.button, action = step.mode or "click" }
	elseif action == "click_object" then
		return ClickObject,
			{ path = step.path, button = step.button, action = step.mode or "click", force = step.force }
	elseif action == "drag" then
		return MouseDrag,
			{
				from_path = step.from_path,
				from_x = step.from_x,
				from_y = step.from_y,
				to_path = step.to_path,
				to_x = step.to_x,
				to_y = step.to_y,
				button = step.button,
				duration = step.duration,
				steps = step.steps,
			}
	elseif action == "move" then
		return MouseMove, { path = step.path, x = step.x, y = step.y }
	elseif action == "key" then
		return SendKey, { key = step.key, action = step.mode or "tap", duration = step.duration }
	elseif action == "text" then
		return SendText, { text = step.text, textbox_path = step.textbox_path, submit = step.submit }
	end
	return nil, nil
end

local function handleInputSequence(args: Types.InputSequenceArgs): string?
	local steps = args.steps
	if type(steps) ~= "table" or #steps == 0 then
		error("input_sequence needs a non-empty steps array")
	end
	if #steps > MAX_STEPS then
		error(string.format("Too many steps (%d): at most %d per call", #steps, MAX_STEPS))
	end

	-- Validate the time budget up front so a bad sequence fails before any
	-- input has been sent.
	local totalSeconds = 0
	for index, step in steps do
		if type(step) ~= "table" or type(step.action) ~= "string" then
			error(string.format("Step %d has no action field", index))
		end
		if step.action == "wait" then
			totalSeconds += math.clamp(if type(step.seconds) == "number" then step.seconds else 0.5, 0, MAX_WAIT)
		elseif type(step.duration) == "number" then
			totalSeconds += math.min(step.duration, 30)
		end
	end
	if totalSeconds > MAX_TOTAL_SECONDS then
		error(
			string.format(
				"The sequence would take about %ds of waits/holds; at most %ds per call",
				totalSeconds,
				MAX_TOTAL_SECONDS
			)
		)
	end

	VirtualInput.assertRendering()

	local results = {}
	for index, step in steps do
		local action = step.action
		local ok: boolean
		local result: any
		if action == "wait" then
			local seconds = math.clamp(if type(step.seconds) == "number" then step.seconds else 0.5, 0, MAX_WAIT)
			task.wait(seconds)
			ok, result = true, HttpService:JSONEncode({ waited = seconds })
		else
			local handler, handlerArgs = buildStep(step)
			if not handler then
				ok = false
				result = string.format(
					"Unknown action %q: must be click, click_object, drag, move, key, text, or wait",
					tostring(action)
				)
			else
				ok, result = pcall(handler, handlerArgs)
			end
		end

		local decoded: any = nil
		if ok and type(result) == "string" then
			local okDecode, value = pcall(function()
				return HttpService:JSONDecode(result :: string)
			end)
			decoded = if okDecode then value else result
		end
		table.insert(results, {
			step = index,
			action = action,
			ok = ok,
			result = if ok then decoded else nil,
			error = if not ok then tostring(result) else nil,
		})

		if not ok then
			return HttpService:JSONEncode({
				completed = index - 1,
				total = #steps,
				failed_step = index,
				error = tostring(result),
				results = results,
			})
		end
	end

	return HttpService:JSONEncode({
		completed = #steps,
		total = #steps,
		results = results,
	})
end

return handleInputSequence :: Types.ToolFunction
