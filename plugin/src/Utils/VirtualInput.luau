--[[
	Wraps UserInputService:CreateVirtualInput(), which drives the engine's
	real input pipeline: SendKey feeds InputBegan/InputEnded and the default
	control scripts (so WASD really walks the character), and SendMouseButton
	activates GuiButtons exactly like a player's click.

	Coordinates are render-area pixels with the topbar inset included, the
	same convention as UiQuery (calibrated empirically).
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local VirtualInput = {}

local BUTTON_TYPES: { [string]: Enum.UserInputType } = {
	left = Enum.UserInputType.MouseButton1,
	right = Enum.UserInputType.MouseButton2,
	middle = Enum.UserInputType.MouseButton3,
}

local cached: any = nil

function VirtualInput.get(): any
	if cached == nil then
		local ok, vi = pcall(function()
			return (UserInputService :: any):CreateVirtualInput()
		end)
		if not ok or vi == nil then
			error(
				"UserInputService:CreateVirtualInput() is not available in this Studio version; "
					.. "input simulation cannot work. ("
					.. tostring(vi)
					.. ")"
			)
		end
		cached = vi
	end
	return cached
end

-- A passed check is cached briefly so bursts of inputs (input_sequence,
-- drags) do not pay the 0.25s sampling cost per event.
local lastRenderOkClock: number? = nil
local RENDER_CHECK_CACHE_SECONDS = 5

-- The engine silently drops virtual input while it is not rendering, which
-- would look like a successful click that did nothing.
function VirtualInput.assertRendering()
	if lastRenderOkClock and os.clock() - lastRenderOkClock < RENDER_CHECK_CACHE_SECONDS then
		return
	end
	local frames = 0
	local conn = RunService.RenderStepped:Connect(function()
		frames += 1
	end)
	task.wait(0.25)
	conn:Disconnect()
	if frames == 0 then
		error(
			"Studio is not rendering (the window is probably minimized or fully covered);"
				.. " input would be silently dropped. Restore the Roblox Studio window and try again."
		)
	end
	lastRenderOkClock = os.clock()
end

function VirtualInput.buttonType(button: string?): Enum.UserInputType
	local inputType = BUTTON_TYPES[button or "left"]
	if not inputType then
		error(string.format("Invalid mouse button %q: must be left, right, or middle", tostring(button)))
	end
	return inputType
end

function VirtualInput.mouseButton(position: Vector2, button: string?, isDown: boolean)
	VirtualInput.get():SendMouseButton(position, VirtualInput.buttonType(button), isDown)
end

-- ClickDetectors and hover-dependent code use the engine's tracked cursor
-- position (only updated by move events), not the position embedded in the
-- button event — so always move there first, like a real player would.
function VirtualInput.pressAt(position: Vector2, button: string?)
	VirtualInput.movePosition(position)
	task.wait(0.03)
	VirtualInput.mouseButton(position, button, true)
end

function VirtualInput.click(position: Vector2, button: string?)
	VirtualInput.pressAt(position, button)
	task.wait(0.06)
	VirtualInput.mouseButton(position, button, false)
end

-- Moves the pointer to an absolute viewport position; fires InputChanged
-- (MouseMovement) and updates GetMouseLocation just like a physical move.
function VirtualInput.movePosition(position: Vector2)
	VirtualInput.get():SendMousePosition(position)
end

-- Relative movement; the engine only accepts it while the cursor is locked
-- (e.g. during a right-button camera drag).
function VirtualInput.moveDelta(delta: Vector2)
	VirtualInput.get():SendMouseDelta(delta)
end

function VirtualInput.key(keyCode: Enum.KeyCode, isDown: boolean)
	VirtualInput.get():SendKey(isDown, keyCode)
end

function VirtualInput.text(input: string)
	VirtualInput.get():SendTextInput(input)
end

return VirtualInput
