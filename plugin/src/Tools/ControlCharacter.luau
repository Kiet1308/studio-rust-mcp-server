--[[
	High-level character control on the play-mode client: walk to a position,
	walk in a direction, jump, stop, or report the character's state.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MAX_MOVE_SECONDS = 60
local DEFAULT_MOVE_SECONDS = 15

local function getHumanoid(): (Humanoid, BasePart)
	local player = Players.LocalPlayer
	if not player then
		error("No LocalPlayer: control_character only works during play mode")
	end
	local character = player.Character
	if not character then
		error("The player has no character (it may still be spawning); try again shortly")
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		error("The character has no Humanoid/HumanoidRootPart")
	end
	return humanoid, rootPart
end

local function vector3ToTable(v: Vector3): { number }
	return { math.round(v.X * 100) / 100, math.round(v.Y * 100) / 100, math.round(v.Z * 100) / 100 }
end

local function handleControlCharacter(args: Types.ControlCharacterArgs): string?
	local action = args.action
	local humanoid, rootPart = getHumanoid()

	if action == "get_state" then
		local camera = workspace.CurrentCamera
		return HttpService:JSONEncode({
			position = vector3ToTable(rootPart.Position),
			velocity = vector3ToTable(rootPart.AssemblyLinearVelocity),
			move_direction = vector3ToTable(humanoid.MoveDirection),
			state = humanoid:GetState().Name,
			health = humanoid.Health,
			max_health = humanoid.MaxHealth,
			walk_speed = humanoid.WalkSpeed,
			jump_power = humanoid.JumpPower,
			seated = humanoid.Sit,
			camera_position = if camera then vector3ToTable(camera.CFrame.Position) else nil,
			camera_look = if camera then vector3ToTable(camera.CFrame.LookVector) else nil,
		})
	elseif action == "jump" then
		humanoid.Jump = true
		task.wait(0.4)
		return HttpService:JSONEncode({ jumped = true, state = humanoid:GetState().Name })
	elseif action == "stop" then
		humanoid:Move(Vector3.zero)
		humanoid:MoveTo(rootPart.Position)
		return HttpService:JSONEncode({ stopped = true, position = vector3ToTable(rootPart.Position) })
	elseif action == "move_to" then
		if type(args.x) ~= "number" or type(args.y) ~= "number" or type(args.z) ~= "number" then
			error("move_to needs x, y, and z world coordinates")
		end
		local destination = Vector3.new(args.x, args.y, args.z)
		local timeout = math.clamp(
			if type(args.duration) == "number" then args.duration else DEFAULT_MOVE_SECONDS,
			1,
			MAX_MOVE_SECONDS
		)
		humanoid:MoveTo(destination)
		local reached = false
		local finished = false
		local conn = humanoid.MoveToFinished:Connect(function(didReach)
			reached = didReach
			finished = true
		end)
		local waited = 0
		while not finished and waited < timeout do
			task.wait(0.1)
			waited += 0.1
		end
		conn:Disconnect()
		-- Note: MoveToFinished fires with reached=false when the engine's own
		-- 8 second MoveTo timeout expires before arrival.
		return HttpService:JSONEncode({
			reached = reached,
			timed_out = not finished,
			position = vector3ToTable(rootPart.Position),
			distance_left = math.round((rootPart.Position - destination).Magnitude * 100) / 100,
		})
	elseif action == "walk" then
		if type(args.x) ~= "number" or type(args.z) ~= "number" then
			error("walk needs x and z direction components (world space, y ignored)")
		end
		local direction = Vector3.new(args.x, 0, args.z)
		if direction.Magnitude < 0.001 then
			error("walk direction must not be zero")
		end
		direction = direction.Unit
		local duration = math.clamp(
			if type(args.duration) == "number" then args.duration else 1,
			0.1,
			MAX_MOVE_SECONDS
		)
		-- The default control scripts reassert the move direction every
		-- frame, so keep applying ours until the duration elapses.
		local elapsed = 0
		while elapsed < duration do
			humanoid:Move(direction, false)
			elapsed += RunService.Heartbeat:Wait()
		end
		humanoid:Move(Vector3.zero)
		return HttpService:JSONEncode({
			walked = duration,
			position = vector3ToTable(rootPart.Position),
		})
	end

	error(
		string.format(
			"Invalid action %q: must be move_to, walk, jump, stop, or get_state",
			tostring(action)
		)
	)
end

return handleControlCharacter :: Types.ToolFunction
