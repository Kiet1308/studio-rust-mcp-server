--[[
	Finds UI elements by text/name/class without dumping the whole tree —
	get_ui_tree's depth limit hides deep elements, and a real game's PlayerGui
	is too large to scan by hand. Matches are limited to elements actually on
	screen unless include_offscreen, and each visible match is hit-tested so
	covered elements are flagged before anyone tries to click them.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)

local HttpService = game:GetService("HttpService")

local DEFAULT_LIMIT = 20
local MAX_LIMIT = 100
-- The per-element occlusion hit-test costs more than the scan; bound it.
local MAX_OCCLUSION_CHECKS = 30

local function hasText(gui: GuiObject): boolean
	return gui:IsA("TextLabel") or gui:IsA("TextButton") or gui:IsA("TextBox")
end

local function handleFindUi(args: Types.FindUiArgs): string?
	local textNeedle = if type(args.text) == "string" and args.text ~= "" then string.lower(args.text) else nil
	local nameNeedle = if type(args.name) == "string" and args.name ~= "" then string.lower(args.name) else nil
	local className = if type(args.class) == "string" and args.class ~= "" then args.class else nil
	if not (textNeedle or nameNeedle or className) then
		error("find_ui needs at least one of text, name, or class")
	end

	local guiRoot = UiQuery.guiRoot()
	local root: Instance = guiRoot
	if args.root and args.root ~= "" then
		root = UiQuery.resolve(args.root)
	end

	local includeOffscreen = args.include_offscreen == true
	local limit = math.clamp(if type(args.limit) == "number" then args.limit else DEFAULT_LIMIT, 1, MAX_LIMIT)

	local matches = {}
	local occlusionChecks = 0
	local truncated = false
	for _, descendant in root:GetDescendants() do
		if not descendant:IsA("GuiObject") then
			continue
		end
		local gui = descendant :: GuiObject
		if textNeedle then
			if not hasText(gui) then
				continue
			end
			if not string.find(string.lower((gui :: TextLabel).Text), textNeedle, 1, true) then
				continue
			end
		end
		if nameNeedle and not string.find(string.lower(gui.Name), nameNeedle, 1, true) then
			continue
		end
		if className and gui.ClassName ~= className then
			local okIsA, isA = pcall(gui.IsA, gui, className)
			if not okIsA or not isA then
				continue
			end
		end
		local onScreen = UiQuery.isOnScreen(gui)
		if not onScreen and not includeOffscreen then
			continue
		end
		if #matches >= limit then
			truncated = true
			break
		end

		local rect = UiQuery.viewportRect(gui)
		local entry: { [string]: any } = {
			path = UiQuery.relativePath(gui, guiRoot),
			class = gui.ClassName,
			rect = { rect.x, rect.y, rect.w, rect.h },
			on_screen = onScreen,
		}
		if hasText(gui) then
			entry.text = (gui :: TextLabel).Text
		end
		if gui:IsA("GuiButton") then
			entry.clickable = true
		end
		if gui:IsA("TextBox") then
			entry.editable = true
		end
		if onScreen and occlusionChecks < MAX_OCCLUSION_CHECKS then
			occlusionChecks += 1
			local occluder = UiQuery.occluderAt(UiQuery.clickPoint(gui), gui)
			if occluder then
				entry.covered_by = occluder:GetFullName()
			end
		end
		table.insert(matches, entry)
	end

	return HttpService:JSONEncode({
		matches = matches,
		count = #matches,
		truncated = truncated,
	})
end

return handleFindUi :: Types.ToolFunction
