local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)

local tools: { [string]: Types.ToolFunction } = {
	["ClickObject"] = require(Main.Tools.ClickObject),
	["ClickUi"] = require(Main.Tools.ClickUi),
	["ControlCharacter"] = require(Main.Tools.ControlCharacter),
	["GetConsoleOutput"] = require(Main.Tools.GetConsoleOutput),
	["GetErrors"] = require(Main.Tools.GetErrors),
	["GetStudioMode"] = require(Main.Tools.GetStudioMode),
	["GetUiTree"] = require(Main.Tools.GetUiTree),
	["InputSequence"] = require(Main.Tools.InputSequence),
	["InsertModel"] = require(Main.Tools.InsertModel),
	["MouseDrag"] = require(Main.Tools.MouseDrag),
	["MouseMove"] = require(Main.Tools.MouseMove),
	["RunCode"] = require(Main.Tools.RunCode),
	["RunScriptInPlayMode"] = require(Main.Tools.RunScriptInPlayMode),
	["SendKey"] = require(Main.Tools.SendKey),
	["SendText"] = require(Main.Tools.SendText),
	["SetCamera"] = require(Main.Tools.SetCamera),
	["StartStopPlay"] = require(Main.Tools.StartStopPlay),
	["TakeScreenshotCapture"] = require(Main.Tools.TakeScreenshotCapture),
	["TakeScreenshotRead"] = require(Main.Tools.TakeScreenshotRead),
	["WaitFor"] = require(Main.Tools.WaitFor),
}

local function dispatchTool(toolName: string, args: Types.ToolArgs): string?
	local toolFunction = tools[toolName]
	if not toolFunction then
		error("Tool " .. toolName .. " not found")
	end

	return toolFunction(args)
end

return {
	tools = tools,
	dispatchTool = dispatchTool,
}
