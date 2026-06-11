-- LocalScript counterpart of Main.server.luau: plugin Scripts never run in the
-- play-mode client DataModel, so this entry boots the plugin there. Input
-- simulation and screen capture must run on the client because it is the only
-- DataModel that renders and owns the LocalPlayer during play.
local RunService = game:GetService("RunService")

if not (RunService:IsRunning() and RunService:IsClient()) then
	return
end

local Main = script:FindFirstAncestor("MCPStudioPlugin")
require(Main.PluginMain).run(plugin)
