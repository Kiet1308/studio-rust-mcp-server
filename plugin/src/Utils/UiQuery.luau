--[[
	Helpers for locating and describing GUI elements.

	Coordinate convention (calibrated empirically): VirtualInput mouse
	positions and screenshot pixels are in render-area coordinates whose
	origin is the top-left of the viewport INCLUDING the topbar inset.
	GuiObject.AbsolutePosition excludes the inset, so GuiService:GetGuiInset()
	is added when converting.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UiQuery = {}

export type Rect = { x: number, y: number, w: number, h: number }

-- The default root for relative paths: PlayerGui during play on the client,
-- StarterGui otherwise (edit mode shows StarterGui contents in the viewport).
function UiQuery.guiRoot(): Instance
	if RunService:IsRunning() and RunService:IsClient() then
		local player = Players.LocalPlayer
		local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			return playerGui
		end
	end
	return game:GetService("StarterGui")
end

local function childNames(parent: Instance): string
	local names = {}
	for _, child in parent:GetChildren() do
		table.insert(names, child.Name)
		if #names >= 30 then
			table.insert(names, "...")
			break
		end
	end
	return table.concat(names, ", ")
end

-- Backtracking resolution: tries the plain segment first, then progressively
-- longer joins of the following segments, so instance names that themselves
-- contain "." still resolve. `deepest` records where resolution got furthest
-- for the error message.
local function resolveFrom(
	current: Instance,
	segments: { string },
	index: number,
	deepest: { node: Instance, index: number }
): Instance?
	if index > #segments then
		return current
	end
	if index > deepest.index then
		deepest.node = current
		deepest.index = index
	end
	local name = segments[index]
	for last = index, #segments do
		if last > index then
			name ..= "." .. segments[last]
		end
		local child = current:FindFirstChild(name)
		if not child and current == game then
			-- Allow service names at the top level ("game.Workspace...").
			local ok, service = pcall(game.GetService, game, name)
			child = if ok then service else nil
		end
		if child then
			local resolved = resolveFrom(child, segments, last + 1, deepest)
			if resolved then
				return resolved
			end
		end
	end
	return nil
end

-- Resolves a dot-separated path ("ShopGui.Frame.BuyButton") relative to the
-- gui root. Also accepts absolute paths starting with "game", or with the
-- root's own name ("PlayerGui...." / "StarterGui....").
function UiQuery.resolve(path: string): Instance
	local segments = string.split(path, ".")
	if path == "" or #segments == 0 then
		error("Empty UI path")
	end

	local current: Instance
	local startIndex = 1
	local first = segments[1]
	if first == "game" then
		current = game
		startIndex = 2
	elseif first == "PlayerGui" or first == "StarterGui" then
		current = UiQuery.guiRoot()
		startIndex = 2
	else
		current = UiQuery.guiRoot()
	end
	if startIndex > #segments then
		return current
	end

	local deepest = { node = current, index = startIndex }
	local resolved = resolveFrom(current, segments, startIndex, deepest)
	if not resolved then
		error(
			string.format(
				"UI path %q not found: %q has no child %q. Available children: %s",
				path,
				deepest.node:GetFullName(),
				segments[deepest.index] or "?",
				childNames(deepest.node)
			)
		)
	end
	return resolved
end

-- A path for the element relative to the gui root, in the form the UI tools
-- accept back (find_ui results feed click_ui directly).
function UiQuery.relativePath(gui: Instance, root: Instance): string
	local parts = {}
	local node: Instance? = gui
	while node and node ~= root do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	if node ~= root then
		return gui:GetFullName()
	end
	return table.concat(parts, ".")
end

-- Resolves a path to a 3D object. Bare paths are relative to Workspace
-- ("Ball1", "Arena.Table.Ball1"); absolute paths start with "game." or
-- "Workspace.".
function UiQuery.resolveWorld(path: string): PVInstance
	local segments = string.split(path, ".")
	if segments[1] == "workspace" then
		segments[1] = "Workspace"
	end
	local full: string
	if segments[1] == "game" then
		full = table.concat(segments, ".")
	elseif segments[1] == "Workspace" then
		full = "game." .. table.concat(segments, ".")
	else
		full = "game.Workspace." .. table.concat(segments, ".")
	end
	local target = UiQuery.resolve(full)
	if not target:IsA("PVInstance") then
		error(
			string.format(
				"Path %q resolved to %s (%s), which has no 3D position",
				path,
				target:GetFullName(),
				target.ClassName
			)
		)
	end
	return target :: PVInstance
end

-- The element's bounding rectangle in render-area pixels (inset included),
-- clamped to the viewport.
function UiQuery.viewportRect(gui: GuiObject): Rect
	local inset = GuiService:GetGuiInset()
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(math.huge, math.huge)
	local x = gui.AbsolutePosition.X + inset.X
	local y = gui.AbsolutePosition.Y + inset.Y
	local w = gui.AbsoluteSize.X
	local h = gui.AbsoluteSize.Y
	local x0 = math.clamp(x, 0, viewport.X)
	local y0 = math.clamp(y, 0, viewport.Y)
	local x1 = math.clamp(x + w, 0, viewport.X)
	local y1 = math.clamp(y + h, 0, viewport.Y)
	return { x = x0, y = y0, w = math.max(0, x1 - x0), h = math.max(0, y1 - y0) }
end

-- Where to click the element: its center in render-area pixels.
function UiQuery.clickPoint(gui: GuiObject): Vector2
	local inset = GuiService:GetGuiInset()
	local center = gui.AbsolutePosition + gui.AbsoluteSize / 2
	return Vector2.new(center.X + inset.X, center.Y + inset.Y)
end

local MAX_NODES = 800

local function serializeNode(instance: Instance, depth: number, maxDepth: number, includeInvisible: boolean, budget: { count: number }): any?
	if budget.count >= MAX_NODES then
		return nil
	end

	local isGuiObject = instance:IsA("GuiObject")
	local isContainer = instance:IsA("LayerCollector") or instance:IsA("Folder") or isGuiObject
	if not isContainer then
		return nil
	end
	if isGuiObject and not includeInvisible and not (instance :: GuiObject).Visible then
		return nil
	end
	if instance:IsA("LayerCollector") and not includeInvisible and not (instance :: LayerCollector).Enabled then
		return nil
	end

	budget.count += 1
	local node: { [string]: any } = {
		name = instance.Name,
		class = instance.ClassName,
	}

	if isGuiObject then
		local gui = instance :: GuiObject
		local rect = UiQuery.viewportRect(gui)
		node.rect = { rect.x, rect.y, rect.w, rect.h }
		if not gui.Visible then
			node.visible = false
		end
		if gui.ZIndex ~= 1 then
			node.zindex = gui.ZIndex
		end
		if gui:IsA("TextLabel") or gui:IsA("TextButton") or gui:IsA("TextBox") then
			node.text = (gui :: TextLabel).Text
		end
		if gui:IsA("TextBox") then
			node.editable = true
		end
		if gui:IsA("GuiButton") then
			node.clickable = true
		end
		if gui:IsA("ImageLabel") or gui:IsA("ImageButton") then
			local image = (gui :: ImageLabel).Image
			if image ~= "" then
				node.image = image
			end
		end
	end

	if depth < maxDepth then
		local children = {}
		for _, child in instance:GetChildren() do
			local childNode = serializeNode(child, depth + 1, maxDepth, includeInvisible, budget)
			if childNode then
				table.insert(children, childNode)
			end
		end
		if #children > 0 then
			node.children = children
		end
	end

	return node
end

local function siblingIndex(inst: Instance): number
	local parent = inst.Parent
	if not parent then
		return 0
	end
	for i, child in parent:GetChildren() do
		if child == inst then
			return i
		end
	end
	return 0
end

-- The LayerCollector a GuiObject renders in, plus the ancestor chain from the
-- layer's direct child down to the object itself (may include Folders).
local function layerChain(gui: GuiObject): (LayerCollector?, { Instance })
	local chain: { Instance } = {}
	local node: Instance? = gui
	while node and not node:IsA("LayerCollector") do
		table.insert(chain, 1, node)
		node = node.Parent
	end
	return if node then node :: LayerCollector else nil, chain
end

local function zOf(inst: Instance): number
	return if inst:IsA("GuiObject") then (inst :: GuiObject).ZIndex else 0
end

-- Whether `a` draws above `b`: DisplayOrder across LayerCollectors, then
-- ZIndex/tree order within one (covering both Sibling and Global behaviors).
function UiQuery.rendersAbove(a: GuiObject, b: GuiObject): boolean
	local layerA, chainA = layerChain(a)
	local layerB, chainB = layerChain(b)
	if layerA ~= layerB then
		if not layerA then
			return false
		end
		if not layerB then
			return true
		end
		local da = if layerA:IsA("ScreenGui") then (layerA :: ScreenGui).DisplayOrder else 0
		local db = if layerB:IsA("ScreenGui") then (layerB :: ScreenGui).DisplayOrder else 0
		if da ~= db then
			return da > db
		end
		return siblingIndex(layerA) > siblingIndex(layerB)
	end
	if layerA and layerA.ZIndexBehavior == Enum.ZIndexBehavior.Global then
		if a.ZIndex ~= b.ZIndex then
			return a.ZIndex > b.ZIndex
		end
	end
	for i = 1, math.min(#chainA, #chainB) do
		local ca, cb = chainA[i], chainB[i]
		if ca ~= cb then
			if zOf(ca) ~= zOf(cb) then
				return zOf(ca) > zOf(cb)
			end
			return siblingIndex(ca) > siblingIndex(cb)
		end
	end
	-- One is an ancestor of the other; the deeper element draws on top of it.
	return #chainA > #chainB
end

-- Whether `obj` would intercept a click meant for `target` (nil target = a
-- click aimed at the 3D world). Button activation routing only considers
-- interactive elements — a plain Active frame does NOT steal a click from a
-- GuiButton below it (verified empirically) — but Active elements do sink
-- input aimed at the world or at InputBegan-style handlers.
local function intercepts(obj: GuiObject, target: GuiObject?): boolean
	if obj:IsA("GuiButton") or obj:IsA("TextBox") then
		return true
	end
	return obj.Active and not (target and target:IsA("GuiButton"))
end

-- The topmost element that would swallow a click at `position` (render-area
-- pixels). With `target` given, the target itself, its descendants/ancestors,
-- and anything it draws above do not count — what is returned really would
-- receive the click instead of the target.
function UiQuery.occluderAt(position: Vector2, target: GuiObject?): GuiObject?
	local root = UiQuery.guiRoot()
	if not root:IsA("BasePlayerGui") then
		return nil
	end
	local inset = GuiService:GetGuiInset()
	local objects =
		(root :: any):GetGuiObjectsAtPosition(position.X - inset.X, position.Y - inset.Y) :: { GuiObject }
	local top: GuiObject? = nil
	for _, obj in objects do
		if not (obj:IsA("GuiObject") and obj.Visible and intercepts(obj, target)) then
			continue
		end
		if target and (obj == target or obj:IsDescendantOf(target) or target:IsDescendantOf(obj)) then
			continue
		end
		if not top or UiQuery.rendersAbove(obj, top) then
			top = obj
		end
	end
	if top and target and not UiQuery.rendersAbove(top, target) then
		return nil
	end
	return top
end

-- Whether the element is actually rendered and at least partly inside the
-- viewport: self and ancestors visible, layer enabled, nonzero on-screen area.
function UiQuery.isOnScreen(gui: GuiObject): boolean
	if gui.AbsoluteSize.X < 1 or gui.AbsoluteSize.Y < 1 then
		return false
	end
	local node: Instance? = gui
	while node do
		if node:IsA("GuiObject") and not (node :: GuiObject).Visible then
			return false
		end
		if node:IsA("LayerCollector") then
			if not (node :: LayerCollector).Enabled then
				return false
			end
			break
		end
		node = node.Parent
	end
	local rect = UiQuery.viewportRect(gui)
	return rect.w >= 1 and rect.h >= 1
end

-- Serializes the UI hierarchy under root into a compact tree the model can
-- reason about: names, classes, screen rectangles, text, interactability.
function UiQuery.serializeTree(root: Instance, maxDepth: number, includeInvisible: boolean): any
	local budget = { count = 0 }
	local nodes = {}
	if root:IsA("GuiObject") or root:IsA("LayerCollector") then
		local node = serializeNode(root, 1, maxDepth, includeInvisible, budget)
		if node then
			table.insert(nodes, node)
		end
	else
		for _, child in root:GetChildren() do
			local node = serializeNode(child, 1, maxDepth, includeInvisible, budget)
			if node then
				table.insert(nodes, node)
			end
		end
	end
	return {
		root = root:GetFullName(),
		truncated = budget.count >= MAX_NODES,
		nodes = nodes,
	}
end

return UiQuery
