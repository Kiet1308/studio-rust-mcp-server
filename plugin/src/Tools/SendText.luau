--[[
	Types text into a TextBox through the real input pipeline. If a textbox
	path is given it is focused first; otherwise the currently focused
	TextBox receives the text. Runs on the play-mode client.
]]

local Main = script:FindFirstAncestor("MCPStudioPlugin")
local Types = require(Main.Types)
local UiQuery = require(Main.Utils.UiQuery)
local VirtualInput = require(Main.Utils.VirtualInput)

local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local function handleSendText(args: Types.SendTextArgs): string?
	if type(args.text) ~= "string" then
		error("Missing text in SendText")
	end

	VirtualInput.assertRendering()

	local textBox: TextBox? = nil
	if args.textbox_path and args.textbox_path ~= "" then
		local target = UiQuery.resolve(args.textbox_path)
		if not target:IsA("TextBox") then
			error(
				string.format(
					"Path %q resolved to %s (%s), which is not a TextBox",
					args.textbox_path,
					target:GetFullName(),
					target.ClassName
				)
			)
		end
		textBox = target
		target:CaptureFocus()
		task.wait(0.1)
	else
		local focused = UserInputService:GetFocusedTextBox()
		if not focused then
			error(
				"No TextBox is focused. Pass textbox_path so the right TextBox can be focused first,"
					.. " or click one with click_ui."
			)
		end
		textBox = focused
	end

	VirtualInput.text(args.text)
	task.wait(0.1)

	-- Read the text before releasing focus: some games clear the box on
	-- submit, and the caller wants to know what was actually typed.
	local textAfter = if textBox then textBox.Text else nil

	if textBox then
		-- A focused TextBox swallows all later key input (exactly like for a
		-- real player typing), which would silently break send_key afterwards.
		-- Always release; submit controls whether the release presses Enter.
		textBox:ReleaseFocus(args.submit == true)
		task.wait(0.05)
	end

	return HttpService:JSONEncode({
		typed = args.text,
		textbox = if textBox then textBox:GetFullName() else nil,
		text_after = textAfter,
		submitted = args.submit == true,
	})
end

return handleSendText :: Types.ToolFunction
