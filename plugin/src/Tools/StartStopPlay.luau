local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local StudioTestService = game:GetService("StudioTestService")
local GameStopUtil = require(Main.Utils.GameStopUtil)
local GlobalVariables = require(Main.Utils.GlobalVariables)
local InstanceIdentity = require(Main.Utils.InstanceIdentity)

-- The previous session keeps "starting" blocked for a few seconds after stop
-- while Studio tears it down ("Previous call to start play session has not
-- been completed"), so a failed start is retried until this deadline.
local START_TIMEOUT_SECONDS = 10
local START_RETRY_INTERVAL = 0.5
-- How long a still-yielding Execute*ModeAsync call is taken to mean the
-- session is starting (it only returns when the session ends).
local START_CONFIRM_SECONDS = 0.3

-- Lets a session thread that outlived its session avoid resetting state that
-- a newer session now owns.
local sessionGeneration = 0

local function startSession(mode: Types.TestMode, startedMessage: string): string?
	if GlobalVariables.studioMode ~= "stop" then
		return "Already in " .. GlobalVariables.studioMode .. " mode"
	end

	local deadline = os.clock() + START_TIMEOUT_SECONDS
	local lastError = "unknown error"
	while true do
		-- Let the booting play DataModels know which Studio window they
		-- belong to. Re-marked per attempt to keep the timestamp fresh.
		InstanceIdentity.markPlayOwner(GlobalVariables.instanceId)

		sessionGeneration += 1
		local generation = sessionGeneration
		local done = false
		local started = false
		local errorMessage: string? = nil
		task.spawn(function()
			local ok, err = pcall(function()
				if mode == "start_play" then
					return StudioTestService:ExecutePlayModeAsync({})
				end
				return StudioTestService:ExecuteRunModeAsync({})
			end)
			done = true
			if not ok then
				errorMessage = tostring(err)
			end
			-- Execute*ModeAsync returning means the session (if it started)
			-- has ended — including stops from the Studio UI that this plugin
			-- never sees otherwise. Reflect that, unless a newer session has
			-- taken over the mode since.
			if started and sessionGeneration == generation and GlobalVariables.studioMode == mode then
				GlobalVariables.studioMode = "stop"
			end
		end)

		local waited = 0
		while not done and waited < START_CONFIRM_SECONDS do
			waited += task.wait(0.05)
		end
		if not done then
			-- Still yielding: the call only returns when the session ends, so
			-- the session is live.
			started = true
			GlobalVariables.studioMode = mode
			return startedMessage
		end

		lastError = errorMessage or "the call returned immediately"
		if os.clock() >= deadline then
			break
		end
		task.wait(START_RETRY_INTERVAL)
	end

	error(
		string.format(
			"Could not start %s within %d seconds: %s."
				.. " If a play session is already running (e.g. started manually in Studio), stop it first with mode=stop.",
			mode,
			START_TIMEOUT_SECONDS,
			lastError
		)
	)
end

local function stop(): string?
	GameStopUtil.stopPlay()
	wait(1)
	GlobalVariables.studioMode = "stop"
	return "Stopped"
end

local function handleStartStopPlay(startStopPlayArgs: Types.StartStopPlayArgs): string?
	if type(startStopPlayArgs.mode) ~= "string" then
		error("Missing mode in StartStopPlay")
	end

	if startStopPlayArgs.mode == "start_play" then
		return startSession("start_play", "Started play")
	elseif startStopPlayArgs.mode == "stop" then
		return stop()
	elseif startStopPlayArgs.mode == "run_server" then
		return startSession("run_server", "Ran server")
	end

	error("Invalid mode in StartStopPlay, must be start_play, stop, or run_server")
end

return handleStartStopPlay :: Types.ToolFunction
