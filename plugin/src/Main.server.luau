local RunService = game:GetService("RunService")

-- Plugin Scripts do not run in the play-mode client DataModel; that context is
-- bootstrapped by MainClient.client.luau instead.
if RunService:IsRunning() and RunService:IsClient() then
	return
end

local Main = script:FindFirstAncestor("MCPStudioPlugin")
require(Main.PluginMain).run(plugin)
