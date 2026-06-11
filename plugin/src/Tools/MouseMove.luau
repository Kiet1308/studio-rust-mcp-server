--[[
	Moves the mouse pointer like a real player, without clicking — for hover
	states (MouseEnter, tooltips) and for positioning before a click or drag.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)
local VirtualInput = require(Main.Utils.VirtualInput)

local HttpService = game:GetService("HttpService")

local function handleMouseMove(args: Types.MouseMoveArgs): string?
	VirtualInput.assertRendering()

	local position: Vector2
	local targetName: string? = nil
	if args.path and args.path ~= "" then
		local target = UiQuery.resolve(args.path)
		if not target:IsA("GuiObject") then
			error(
				string.format(
					"UI path %q resolved to %s (%s), which is not a GuiObject",
					args.path,
					target:GetFullName(),
					target.ClassName
				)
			)
		end
		position = UiQuery.clickPoint(target)
		targetName = target:GetFullName()
	elseif type(args.x) == "number" and type(args.y) == "number" then
		position = Vector2.new(args.x, args.y)
	else
		error("mouse_move needs either a path or both x and y viewport coordinates")
	end

	VirtualInput.movePosition(position)
	task.wait(0.1)

	return HttpService:JSONEncode({
		x = position.X,
		y = position.Y,
		target = targetName,
	})
end

return handleMouseMove :: Types.ToolFunction
