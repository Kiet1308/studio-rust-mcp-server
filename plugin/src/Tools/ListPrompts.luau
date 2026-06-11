--[[
	Lists nearby ProximityPrompts so interactables can be discovered without
	hand-written workspace scans: which key, hold time, where, and whether the
	character is in range. Triggering stays player-like: send_key with the
	prompt's key (duration >= hold_duration for hold prompts) once in range.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local DEFAULT_MAX_DISTANCE = 100
local DEFAULT_LIMIT = 20
local MAX_LIMIT = 100

local function promptPosition(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if not parent then
		return nil
	end
	if parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	if parent:IsA("BasePart") then
		return parent.Position
	end
	if parent:IsA("Model") then
		return (parent :: Model):GetPivot().Position
	end
	return nil
end

local function handleListPrompts(args: Types.ListPromptsArgs): string?
	local maxDistance = math.clamp(
		if type(args.max_distance) == "number" then args.max_distance else DEFAULT_MAX_DISTANCE,
		5,
		10000
	)
	local limit = math.clamp(if type(args.limit) == "number" then args.limit else DEFAULT_LIMIT, 1, MAX_LIMIT)

	local camera = workspace.CurrentCamera
	local player = Players.LocalPlayer
	local character = player and player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local origin: Vector3
	if hrp then
		origin = (hrp :: BasePart).Position
	elseif camera then
		origin = camera.CFrame.Position
	else
		origin = Vector3.zero
	end

	local found: { { prompt: ProximityPrompt, position: Vector3, distance: number } } = {}
	for _, descendant in workspace:GetDescendants() do
		if not descendant:IsA("ProximityPrompt") then
			continue
		end
		local prompt = descendant :: ProximityPrompt
		if not prompt.Enabled then
			continue
		end
		local position = promptPosition(prompt)
		if not position then
			continue
		end
		local distance = (position - origin).Magnitude
		if distance > maxDistance then
			continue
		end
		table.insert(found, { prompt = prompt, position = position, distance = distance })
	end
	table.sort(found, function(a, b)
		return a.distance < b.distance
	end)

	local truncated = #found > limit
	local prompts = {}
	for i = 1, math.min(limit, #found) do
		local item = found[i]
		local prompt = item.prompt
		local entry: { [string]: any } = {
			path = (prompt.Parent :: Instance):GetFullName(),
			action_text = prompt.ActionText,
			object_text = prompt.ObjectText,
			key = prompt.KeyboardKeyCode.Name,
			hold_duration = prompt.HoldDuration,
			max_activation_distance = prompt.MaxActivationDistance,
			requires_line_of_sight = prompt.RequiresLineOfSight,
			distance = math.floor(item.distance * 10 + 0.5) / 10,
			in_range = item.distance <= prompt.MaxActivationDistance,
			position = { x = item.position.X, y = item.position.Y, z = item.position.Z },
		}
		if camera then
			local screen, onScreen = camera:WorldToViewportPoint(item.position)
			entry.screen = { x = math.floor(screen.X), y = math.floor(screen.Y), on_screen = onScreen }
		end
		table.insert(prompts, entry)
	end

	return HttpService:JSONEncode({
		prompts = prompts,
		count = #prompts,
		truncated = truncated,
	})
end

return handleListPrompts :: Types.ToolFunction
