--[[
	Returns the UI hierarchy as a compact JSON tree (names, classes, screen
	rects, text, interactability) so the model can decide what to click
	without pixel hunting. Rects are in the same coordinate system click_ui
	uses, so a rect center can be clicked directly.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)

local HttpService = game:GetService("HttpService")

local DEFAULT_MAX_DEPTH = 6

local function handleGetUiTree(args: Types.GetUiTreeArgs): string?
	local root: Instance
	if args.root and args.root ~= "" then
		root = UiQuery.resolve(args.root)
	else
		root = UiQuery.guiRoot()
	end

	local maxDepth = if type(args.max_depth) == "number" then math.clamp(args.max_depth, 1, 20) else DEFAULT_MAX_DEPTH
	local tree = UiQuery.serializeTree(root, maxDepth, args.include_invisible == true)
	return HttpService:JSONEncode(tree)
end

return handleGetUiTree :: Types.ToolFunction
