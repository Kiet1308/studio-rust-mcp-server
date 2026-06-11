--[[
	Simulates keyboard input through the engine's real input pipeline, so the
	default control scripts respond (WASD walks, Space jumps) and game code
	sees normal InputBegan/InputEnded events. Runs on the play-mode client.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local VirtualInput = require(Main.Utils.VirtualInput)

local HttpService = game:GetService("HttpService")

local MAX_HOLD_SECONDS = 30

local function handleSendKey(args: Types.SendKeyArgs): string?
	if type(args.key) ~= "string" or args.key == "" then
		error("Missing key in SendKey")
	end

	local ok, keyCode = pcall(function()
		return (Enum.KeyCode :: any)[args.key]
	end)
	if not ok or typeof(keyCode) ~= "EnumItem" then
		error(
			string.format(
				"Unknown key %q: use Enum.KeyCode names like W, A, S, D, Space, E, Return, LeftShift",
				tostring(args.key)
			)
		)
	end

	VirtualInput.assertRendering()

	local action = args.action or "tap"
	local duration = math.clamp(if type(args.duration) == "number" then args.duration else 0.06, 0, MAX_HOLD_SECONDS)
	if action == "tap" then
		VirtualInput.key(keyCode, true)
		task.wait(duration)
		VirtualInput.key(keyCode, false)
	elseif action == "press" then
		VirtualInput.key(keyCode, true)
		if type(args.duration) == "number" and args.duration > 0 then
			-- Hold for the requested time, then release.
			task.wait(duration)
			VirtualInput.key(keyCode, false)
			return HttpService:JSONEncode({ key = args.key, action = "held", duration = duration })
		end
	elseif action == "release" then
		VirtualInput.key(keyCode, false)
	else
		error(string.format("Invalid action %q: must be tap, press, or release", tostring(action)))
	end

	return HttpService:JSONEncode({ key = args.key, action = action, duration = duration })
end

return handleSendKey :: Types.ToolFunction
