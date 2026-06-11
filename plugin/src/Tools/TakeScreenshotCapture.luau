--[[
	Step 1 of take_screenshot: runs on whichever DataModel is rendering
	(play client, run-mode server, or edit) and captures the viewport via
	CaptureService. Returns only the temporary contentId plus geometry; the
	pixels are read in step 2 on the edit DataModel, which has the privilege
	to open temporary capture ids from any DataModel in this Studio process.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)
local VirtualInput = require(Main.Utils.VirtualInput)

local CaptureService = game:GetService("CaptureService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- CaptureScreenshot has a known failure mode where the callback never fires;
-- bound the wait so the caller can fall back to an OS-level capture.
local CAPTURE_TIMEOUT_SECONDS = 5
local RENDER_CHECK_SECONDS = 0.4

local function assertRendering()
	local frames = 0
	local conn = RunService.RenderStepped:Connect(function()
		frames += 1
	end)
	task.wait(RENDER_CHECK_SECONDS)
	conn:Disconnect()
	if frames == 0 then
		error(
			"Studio is not rendering (the window is probably minimized or fully covered)."
				.. " Restore the Roblox Studio window and try again."
		)
	end
end

local function captureScreenshot(): string
	local contentId: string? = nil
	task.spawn(function()
		CaptureService:CaptureScreenshot(function(id)
			contentId = id
		end)
	end)
	local waited = 0
	while not contentId and waited < CAPTURE_TIMEOUT_SECONDS do
		task.wait(0.1)
		waited += 0.1
	end
	if not contentId then
		error("CAPTURE_TIMEOUT: CaptureService:CaptureScreenshot never completed")
	end
	return contentId :: string
end

local function handleTakeScreenshotCapture(args: Types.TakeScreenshotCaptureArgs): string?
	assertRendering()

	local target: GuiObject? = nil
	if args.ui_path and args.ui_path ~= "" then
		local resolved = UiQuery.resolve(args.ui_path)
		if not resolved:IsA("GuiObject") then
			error(
				string.format(
					"UI path %q resolved to %s (%s), which is not a GuiObject and has no on-screen bounds",
					args.ui_path,
					resolved:GetFullName(),
					resolved.ClassName
				)
			)
		end
		target = resolved
	end

	-- Optionally hide every other ScreenGui so the captured element stands
	-- alone; state is restored even if the capture fails.
	local hidden: { LayerCollector } = {}
	if args.isolate and target then
		local targetLayer = target:FindFirstAncestorWhichIsA("LayerCollector")
		local root = UiQuery.guiRoot()
		for _, descendant in root:GetChildren() do
			if descendant:IsA("LayerCollector") and descendant ~= targetLayer and descendant.Enabled then
				descendant.Enabled = false
				table.insert(hidden, descendant)
			end
		end
		-- Give the renderer a frame to apply the visibility change.
		task.wait(0.1)
	end

	-- Hover tooltips follow the pointer; parking it in a corner first keeps
	-- them out of the capture. Only play DataModels accept virtual input.
	if args.park_mouse and RunService:IsRunning() then
		pcall(function()
			local camera = workspace.CurrentCamera
			local viewport = if camera then camera.ViewportSize else Vector2.new(800, 600)
			VirtualInput.movePosition(Vector2.new(1, viewport.Y - 1))
		end)
		task.wait(0.1)
	end

	local ok, result = pcall(function()
		local contentId = captureScreenshot()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.zero
		local payload: { [string]: any } = {
			contentId = contentId,
			viewport = { w = viewport.X, h = viewport.Y },
		}
		if target then
			local rect = UiQuery.viewportRect(target)
			if rect.w < 1 or rect.h < 1 then
				error(
					string.format(
						"UI element %s has no visible on-screen area (rect %dx%d). Is it visible and on screen?",
						target:GetFullName(),
						rect.w,
						rect.h
					)
				)
			end
			payload.rect = rect
		end
		return HttpService:JSONEncode(payload)
	end)

	for _, layer in hidden do
		pcall(function()
			layer.Enabled = true
		end)
	end

	if not ok then
		error(result)
	end
	return result
end

return handleTakeScreenshotCapture :: Types.ToolFunction
