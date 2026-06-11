local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

export type GlobalVariables = {
	studioMode: Types.StartStopPlayMode,
	instanceId: string,
}

local GlobalVariables = {
	studioMode = "stop",
	-- Which Studio window this DataModel belongs to; set by PluginMain.
	instanceId = "",
}

return GlobalVariables
