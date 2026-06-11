export type InsertModelArgs = {
	query: string,
}

export type RunCodeArgs = {
	command: string,
	-- Routing hint consumed by the Rust server; present in the payload but
	-- ignored by the tool itself (it always runs in the DataModel it reaches).
	context: string?,
}

export type TestMode = "start_play" | "run_server"

export type StartStopPlayMode = TestMode | "stop"

export type StartStopPlayArgs = {
	mode: StartStopPlayMode,
}

export type RunScriptInPlayModeArgs = {
	code: string,
	timeout: number?,
	mode: TestMode,
}

export type PixelRect = {
	x: number,
	y: number,
	w: number,
	h: number,
}

export type TakeScreenshotCaptureArgs = {
	ui_path: string?,
	isolate: boolean?,
}

export type TakeScreenshotReadArgs = {
	content_id: string,
	viewport_w: number?,
	viewport_h: number?,
	rect: PixelRect?,
}

export type GetUiTreeArgs = {
	root: string?,
	max_depth: number?,
	include_invisible: boolean?,
}

export type ClickUiArgs = {
	path: string?,
	x: number?,
	y: number?,
	button: string?,
	action: string?,
}

export type GetConsoleOutputArgs = {
	context: string?,
	since_seq: number?,
	level: string?,
	limit: number?,
}

export type GetErrorsArgs = {
	context: string?,
	since_seq: number?,
	limit: number?,
}

export type MouseMoveArgs = {
	path: string?,
	x: number?,
	y: number?,
}

export type MouseDragArgs = {
	from_path: string?,
	from_x: number?,
	from_y: number?,
	to_path: string?,
	to_x: number?,
	to_y: number?,
	button: string?,
	duration: number?,
	steps: number?,
}

export type ClickObjectArgs = {
	path: string,
	button: string?,
	action: string?,
	force: boolean?,
}

export type SetCameraArgs = {
	action: string?,
	x: number?,
	y: number?,
	z: number?,
	target_path: string?,
	target_x: number?,
	target_y: number?,
	target_z: number?,
	fov: number?,
}

export type InputSequenceArgs = {
	steps: { { [string]: any } },
}

export type SendKeyArgs = {
	key: string,
	action: string?,
	duration: number?,
}

export type SendTextArgs = {
	text: string,
	textbox_path: string?,
	submit: boolean?,
}

export type ControlCharacterArgs = {
	action: string,
	x: number?,
	y: number?,
	z: number?,
	duration: number?,
}

export type WaitForArgs = {
	condition: string,
	timeout: number?,
	poll_interval: number?,
	context: string?,
}

export type ToolArgs =
	{}
	| { InsertModel: InsertModelArgs }
	| { RunCode: RunCodeArgs }
	| { StartStopPlay: StartStopPlayArgs }
	| { RunScriptInPlayMode: RunScriptInPlayModeArgs }
	| { TakeScreenshotCapture: TakeScreenshotCaptureArgs }
	| { TakeScreenshotRead: TakeScreenshotReadArgs }
	| { GetUiTree: GetUiTreeArgs }
	| { ClickUi: ClickUiArgs }
	| { GetConsoleOutput: GetConsoleOutputArgs }
	| { GetErrors: GetErrorsArgs }
	| { MouseMove: MouseMoveArgs }
	| { MouseDrag: MouseDragArgs }
	| { ClickObject: ClickObjectArgs }
	| { SetCamera: SetCameraArgs }
	| { InputSequence: InputSequenceArgs }
	| { SendKey: SendKeyArgs }
	| { SendText: SendTextArgs }
	| { ControlCharacter: ControlCharacterArgs }
	| { WaitFor: WaitForArgs }

export type ToolFunction = (ToolArgs) -> string?

return {}
