--[[
	Clicks like a real player via the engine's input pipeline. Targets either
	a UI element by path (clicked at its center) or an explicit viewport
	position. Runs on the play-mode client.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)
local VirtualInput = require(Main.Utils.VirtualInput)

local HttpService = game:GetService("HttpService")

local function handleClickUi(args: Types.ClickUiArgs): string?
	VirtualInput.assertRendering()

	local position: Vector2
	local targetName: string? = nil
	if args.path and args.path ~= "" then
		local target = UiQuery.resolve(args.path)
		if not target:IsA("GuiObject") then
			error(
				string.format(
					"UI path %q resolved to %s (%s), which is not a clickable GuiObject",
					args.path,
					target:GetFullName(),
					target.ClassName
				)
			)
		end
		local rect = UiQuery.viewportRect(target)
		if rect.w < 1 or rect.h < 1 then
			error(
				string.format(
					"UI element %s has no visible on-screen area; it cannot be clicked. Is it visible?",
					target:GetFullName()
				)
			)
		end
		position = UiQuery.clickPoint(target)
		targetName = target:GetFullName()
	elseif type(args.x) == "number" and type(args.y) == "number" then
		position = Vector2.new(args.x, args.y)
	else
		error("click_ui needs either a path or both x and y viewport coordinates")
	end

	local action = args.action or "click"
	if action == "click" then
		VirtualInput.click(position, args.button)
	elseif action == "down" then
		VirtualInput.pressAt(position, args.button)
	elseif action == "up" then
		VirtualInput.mouseButton(position, args.button, false)
	else
		error(string.format("Invalid action %q: must be click, down, or up", tostring(action)))
	end

	-- Give the game a beat to react before the caller inspects the result.
	task.wait(0.1)

	return HttpService:JSONEncode({
		action = action,
		button = args.button or "left",
		x = position.X,
		y = position.Y,
		target = targetName,
	})
end

return handleClickUi :: Types.ToolFunction
