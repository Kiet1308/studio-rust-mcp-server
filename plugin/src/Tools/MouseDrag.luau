--[[
	Drags the mouse like a real player: button down at the start point, a
	stream of intermediate move events, button up at the end point. While the
	cursor is locked (e.g. a right-button camera drag), movement is delivered
	as deltas — the only form the engine accepts in that state.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)
local VirtualInput = require(Main.Utils.VirtualInput)

local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local MAX_DURATION = 10

local function resolvePoint(path: string?, x: number?, y: number?, label: string): Vector2
	if path and path ~= "" then
		local target = UiQuery.resolve(path)
		if not target:IsA("GuiObject") then
			error(
				string.format(
					"%s path %q resolved to %s (%s), which is not a GuiObject",
					label,
					path,
					target:GetFullName(),
					target.ClassName
				)
			)
		end
		return UiQuery.clickPoint(target)
	end
	if type(x) == "number" and type(y) == "number" then
		return Vector2.new(x, y)
	end
	error(string.format("mouse_drag needs the %s point: either %s_path or %s_x and %s_y", label, label, label, label))
end

local function handleMouseDrag(args: Types.MouseDragArgs): string?
	VirtualInput.assertRendering()

	local from = resolvePoint(args.from_path, args.from_x, args.from_y, "from")
	local to = resolvePoint(args.to_path, args.to_x, args.to_y, "to")
	local button = args.button or "left"
	local duration = math.clamp(if type(args.duration) == "number" then args.duration else 0.5, 0.05, MAX_DURATION)
	local steps = math.clamp(
		if type(args.steps) == "number" then math.floor(args.steps) else math.ceil(duration * 60),
		2,
		240
	)

	-- "none" sweeps the pointer without holding a button (hover path).
	local pressed = button ~= "none"
	if pressed then
		-- Validate the button name before anything is pressed.
		VirtualInput.buttonType(button)
	end

	VirtualInput.movePosition(from)
	task.wait(0.05)
	if pressed then
		VirtualInput.mouseButton(from, button, true)
		task.wait(0.05)
	end

	local usedDelta = false
	local stepDelta = (to - from) / steps
	local interval = duration / steps
	for i = 1, steps do
		if UserInputService.MouseBehavior == Enum.MouseBehavior.Default then
			VirtualInput.movePosition(from + stepDelta * i)
		else
			-- Locked cursor (camera-style drag): the engine only accepts deltas.
			VirtualInput.moveDelta(stepDelta)
			usedDelta = true
		end
		task.wait(interval)
	end

	if pressed then
		VirtualInput.mouseButton(to, button, false)
	end
	task.wait(0.1)

	return HttpService:JSONEncode({
		from = { x = from.X, y = from.Y },
		to = { x = to.X, y = to.Y },
		button = button,
		duration = duration,
		steps = steps,
		used_delta = usedDelta,
	})
end

return handleMouseDrag :: Types.ToolFunction
