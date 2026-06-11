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
	local target: GuiObject? = nil
	local targetName: string? = nil
	if args.path and args.path ~= "" then
		local resolved = UiQuery.resolve(args.path)
		if not resolved:IsA("GuiObject") then
			error(
				string.format(
					"UI path %q resolved to %s (%s), which is not a clickable GuiObject",
					args.path,
					resolved:GetFullName(),
					resolved.ClassName
				)
			)
		end
		target = resolved
		local rect = UiQuery.viewportRect(resolved)
		if rect.w < 1 or rect.h < 1 then
			error(
				string.format(
					"UI element %s has no visible on-screen area; it cannot be clicked. Is it visible?",
					resolved:GetFullName()
				)
			)
		end
		position = UiQuery.clickPoint(resolved)
		targetName = resolved:GetFullName()
	elseif type(args.x) == "number" and type(args.y) == "number" then
		position = Vector2.new(args.x, args.y)
	else
		error("click_ui needs either a path or both x and y viewport coordinates")
	end

	-- A different Active element drawn on top (a popup, an overlay) would
	-- receive the click — silently, since the engine just routes input to the
	-- topmost element. Surface that instead of clicking blindly. Releases are
	-- exempt: ending a held gesture over a popup is harmless.
	if target and args.force ~= true and (args.action or "click") ~= "up" then
		local occluder = UiQuery.occluderAt(position, target)
		if occluder then
			error(
				string.format(
					"%s is covered at its center by %s, which would receive the click instead."
						.. " Dismiss the covering UI or click it directly, or pass force=true to send the click anyway.",
					target:GetFullName(),
					occluder:GetFullName()
				)
			)
		end
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
