--[[
	Positions the camera for screenshots of specific 3D areas and for
	mouse-driven interactions. Switching to Scriptable stops the default
	camera scripts from fighting the change; restore puts the original
	camera back (do it before handing control back to normal play).
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)

local HttpService = game:GetService("HttpService")

local saved: { cameraType: Enum.CameraType, cframe: CFrame, fov: number }? = nil

local function getCamera(): Camera
	local camera = workspace.CurrentCamera
	if not camera then
		error("No CurrentCamera is available in this DataModel")
	end
	return camera
end

local function resolveTargetPosition(args: Types.SetCameraArgs): Vector3?
	if args.target_path and args.target_path ~= "" then
		return UiQuery.resolveWorld(args.target_path):GetPivot().Position
	end
	if type(args.target_x) == "number" and type(args.target_y) == "number" and type(args.target_z) == "number" then
		return Vector3.new(args.target_x, args.target_y, args.target_z)
	end
	return nil
end

local function describe(camera: Camera)
	local pos = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	return {
		camera_type = tostring(camera.CameraType),
		position = { x = pos.X, y = pos.Y, z = pos.Z },
		look_vector = { x = look.X, y = look.Y, z = look.Z },
		fov = camera.FieldOfView,
		viewport = { w = camera.ViewportSize.X, h = camera.ViewportSize.Y },
		modified = saved ~= nil,
	}
end

local function handleSetCamera(args: Types.SetCameraArgs): string?
	local action = args.action or "get"
	local camera = getCamera()

	if action == "get" then
		return HttpService:JSONEncode(describe(camera))
	end

	if action == "restore" then
		if saved then
			camera.CameraType = saved.cameraType
			camera.CFrame = saved.cframe
			camera.FieldOfView = saved.fov
			saved = nil
		end
		task.wait(0.1)
		return HttpService:JSONEncode(describe(camera))
	end

	if action ~= "set" and action ~= "look_at" and action ~= "frame" then
		error(string.format("Invalid action %q: must be set, look_at, frame, restore, or get", tostring(action)))
	end

	local targetPos = resolveTargetPosition(args)
	local newFov = if type(args.fov) == "number" then math.clamp(args.fov, 1, 120) else camera.FieldOfView
	local newCFrame: CFrame
	if action == "frame" then
		-- Auto-position: back away from the target along a 3/4 diagonal until
		-- its whole bounding box fits the field of view.
		local center: Vector3
		local extent: number
		if args.target_path and args.target_path ~= "" then
			local target = UiQuery.resolveWorld(args.target_path)
			local size: Vector3
			if target:IsA("Model") then
				local cf: CFrame
				cf, size = (target :: Model):GetBoundingBox()
				center = cf.Position
			elseif target:IsA("BasePart") then
				center = (target :: BasePart).Position
				size = (target :: BasePart).Size
			else
				center = target:GetPivot().Position
				size = Vector3.new(4, 4, 4)
			end
			extent = math.max(size.X, size.Y, size.Z, 1)
		elseif targetPos then
			center = targetPos
			extent = 10
		else
			error("frame needs target_path or target_x/target_y/target_z")
		end
		local distance = (extent / 2) / math.tan(math.rad(newFov) / 2) * 1.3 + extent / 2
		local direction = Vector3.new(1, 0.7, 1).Unit
		newCFrame = CFrame.lookAt(center + direction * distance, center)
	elseif action == "set" then
		if type(args.x) ~= "number" or type(args.y) ~= "number" or type(args.z) ~= "number" then
			error("set needs x, y, z for the camera position (and optionally a target to aim at)")
		end
		local position = Vector3.new(args.x, args.y, args.z)
		if targetPos then
			if (targetPos - position).Magnitude < 0.01 then
				error("Camera position and target are the same point; there is no view direction")
			end
			newCFrame = CFrame.lookAt(position, targetPos)
		else
			-- Keep the current view direction, only relocate.
			newCFrame = CFrame.new(position) * camera.CFrame.Rotation
		end
	else -- look_at
		if not targetPos then
			error("look_at needs target_path or target_x/target_y/target_z")
		end
		if (targetPos - camera.CFrame.Position).Magnitude < 0.01 then
			error("The camera is already at the target point; there is no view direction")
		end
		newCFrame = CFrame.lookAt(camera.CFrame.Position, targetPos)
	end

	if saved == nil then
		saved = { cameraType = camera.CameraType, cframe = camera.CFrame, fov = camera.FieldOfView }
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = newCFrame
	camera.FieldOfView = newFov
	-- Let a frame render with the new camera before the caller screenshots.
	task.wait(0.1)

	return HttpService:JSONEncode(describe(camera))
end

return handleSetCamera :: Types.ToolFunction
