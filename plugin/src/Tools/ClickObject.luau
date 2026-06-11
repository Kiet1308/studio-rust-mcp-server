--[[
	Clicks a 3D object in the workspace like a real player: projects its pivot
	to the screen, checks the line of sight, and clicks through the real input
	pipeline — ClickDetectors, raycast-based games, and tools all see a normal
	mouse click at that pixel.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)
local VirtualInput = require(Main.Utils.VirtualInput)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local function handleClickObject(args: Types.ClickObjectArgs): string?
	if type(args.path) ~= "string" or args.path == "" then
		error("click_object needs the path of a workspace object, e.g. 'Shop.Door' or 'Workspace.Ball1'")
	end

	VirtualInput.assertRendering()

	local target = UiQuery.resolveWorld(args.path)
	local camera = workspace.CurrentCamera
	if not camera then
		error("No camera is available in this DataModel")
	end

	local worldPoint = target:GetPivot().Position
	local _, onScreen = camera:WorldToViewportPoint(worldPoint)
	if not onScreen then
		error(
			string.format(
				"%s is off screen (behind or outside the camera view). Aim the camera at it first with"
					.. " set_camera action=look_at target_path=%q, or move the character closer.",
				target:GetFullName(),
				args.path
			)
		)
	end

	-- A click lands on whatever is in front: raycast from the camera toward
	-- the pivot to find the actually-visible surface (the pivot itself is
	-- usually inside the object).
	local origin = camera.CFrame.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		params.FilterDescendantsInstances = { localPlayer.Character }
	end
	local hit = workspace:Raycast(origin, (worldPoint - origin) * 1.05, params)

	local occludedBy: string? = nil
	local clickWorldPoint = worldPoint
	if hit then
		if hit.Instance == target or hit.Instance:IsDescendantOf(target) then
			clickWorldPoint = hit.Position
		else
			occludedBy = hit.Instance:GetFullName()
		end
	end
	if occludedBy and args.force ~= true then
		error(
			string.format(
				"%s is hidden behind %s from the current camera position. Move the camera (set_camera)"
					.. " or the character first, or pass force=true to click that pixel anyway.",
				target:GetFullName(),
				occludedBy
			)
		)
	end

	local screen = camera:WorldToViewportPoint(clickWorldPoint)
	local position = Vector2.new(screen.X, screen.Y)

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
		target = target:GetFullName(),
		action = action,
		button = args.button or "left",
		x = position.X,
		y = position.Y,
		world_point = { x = clickWorldPoint.X, y = clickWorldPoint.Y, z = clickWorldPoint.Z },
		occluded_by = occludedBy,
	})
end

return handleClickObject :: Types.ToolFunction
