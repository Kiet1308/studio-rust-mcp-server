--[[
	Step 2 of take_screenshot: runs on the edit DataModel and turns a
	temporary capture contentId into raw RGBA pixels (base64). Rects arrive in
	viewport coordinates and are scaled to capture pixels here because the
	capture resolution (DPI-scaled) is only known once the image is opened.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Base64 = require(Main.Utils.Base64)
local Types = require(Main.Types)

local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")

-- Above this many raw bytes the image is downscaled in-engine before the
-- pixels are read, keeping encode time and transport size reasonable
-- (a 4K capture is ~33 MB of RGBA).
local MAX_RAW_BYTES = 24 * 1024 * 1024

local function handleTakeScreenshotRead(args: Types.TakeScreenshotReadArgs): string?
	if type(args.content_id) ~= "string" or args.content_id == "" then
		error("Missing content_id in TakeScreenshotRead")
	end

	local image = AssetService:CreateEditableImageAsync(Content.fromUri(args.content_id))

	local readOffset = Vector2.zero
	local readSize = image.Size
	local rect = args.rect
	if rect then
		-- The rect is in viewport coordinates; captures are DPI scaled.
		local scaleX = image.Size.X / math.max(1, args.viewport_w or image.Size.X)
		local scaleY = image.Size.Y / math.max(1, args.viewport_h or image.Size.Y)
		local x0 = math.clamp(math.floor(rect.x * scaleX), 0, image.Size.X - 1)
		local y0 = math.clamp(math.floor(rect.y * scaleY), 0, image.Size.Y - 1)
		local x1 = math.clamp(math.ceil((rect.x + rect.w) * scaleX), x0 + 1, image.Size.X)
		local y1 = math.clamp(math.ceil((rect.y + rect.h) * scaleY), y0 + 1, image.Size.Y)
		readOffset = Vector2.new(x0, y0)
		readSize = Vector2.new(x1 - x0, y1 - y0)
	end

	local source = image
	local rawBytes = readSize.X * readSize.Y * 4
	if rawBytes > MAX_RAW_BYTES then
		local scale = math.sqrt(MAX_RAW_BYTES / rawBytes)
		local targetSize = Vector2.new(
			math.max(1, math.floor(image.Size.X * scale)),
			math.max(1, math.floor(image.Size.Y * scale))
		)
		local ok, downscaled = pcall(function()
			local canvas = AssetService:CreateEditableImage({ Size = targetSize })
			canvas:DrawImageTransformed(Vector2.zero, Vector2.new(scale, scale), 0, image, {
				PivotPoint = Vector2.zero,
			})
			return canvas
		end)
		if ok then
			source = downscaled
			readOffset = Vector2.new(
				math.clamp(math.floor(readOffset.X * scale), 0, targetSize.X - 1),
				math.clamp(math.floor(readOffset.Y * scale), 0, targetSize.Y - 1)
			)
			readSize = Vector2.new(
				math.clamp(math.floor(readSize.X * scale), 1, targetSize.X - readOffset.X),
				math.clamp(math.floor(readSize.Y * scale), 1, targetSize.Y - readOffset.Y)
			)
		end
	end

	local pixelBuffer = source:ReadPixelsBuffer(readOffset, readSize)
	local encoded = Base64.encode(pixelBuffer)

	image:Destroy()
	if source ~= image then
		source:Destroy()
	end

	return HttpService:JSONEncode({
		width = readSize.X,
		height = readSize.Y,
		pixels = encoded,
	})
end

return handleTakeScreenshotRead :: Types.ToolFunction
