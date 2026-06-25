use crate::error::{Report, Result};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{
    extract::{Query, State},
    Json, Router,
};
use color_eyre::eyre::{eyre, OptionExt};
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{
        CallToolResult, Content, Implementation, ProtocolVersion, ServerCapabilities, ServerInfo,
    },
    schemars, tool, tool_handler, tool_router, ErrorData, ServerHandler,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::sync::{mpsc, watch, Mutex};
use tokio::time::{Duration, Instant};
use uuid::Uuid;

pub const STUDIO_PLUGIN_PORT: u16 = 44755;
const LONG_POLL_DURATION: Duration = Duration::from_secs(15);
// The plugin acks a delivered command within milliseconds of receiving it; a
// missing ack means the long-poll connection died mid-delivery (e.g. Studio
// aborted it while publishing) and the command must be requeued.
const ACK_TIMEOUT: Duration = Duration::from_secs(3);
const INFLIGHT_SWEEP_INTERVAL: Duration = Duration::from_secs(1);
const MAX_DELIVERY_ATTEMPTS: u32 = 5;
// Upper bound for tools whose duration is not known in advance.
const DEFAULT_TOOL_TIMEOUT: Duration = Duration::from_secs(300);
const PLAY_MODE_TIMEOUT_GRACE: Duration = Duration::from_secs(60);
const PORT_REBIND_DELAY: Duration = Duration::from_millis(250);
// A connected plugin instance re-polls at least every second, so a poll older
// than this means that DataModel's plugin is gone (or play mode never started).
const ROLE_FRESHNESS: Duration = Duration::from_secs(3);
// How long to wait for a play-mode DataModel to start polling. Covers the gap
// between start_stop_play returning and the play DataModels loading plugins.
const ROLE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);

/// Which Studio DataModel a command is routed to. Every plugin instance polls
/// with its own role; the edit DataModel always exists, server/client only
/// while play mode is running.
#[derive(Deserialize, Serialize, Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
#[serde(rename_all = "lowercase")]
pub enum TargetRole {
    #[default]
    Edit,
    Server,
    Client,
    // Polls without a role come from plugins older than the role-routing
    // protocol. Commands are never addressed to Legacy, so such plugins starve
    // instead of racing the current plugin for edit-targeted commands (e.g. a
    // second Studio instance that has not been restarted since an update).
    Legacy,
}

impl TargetRole {
    fn describe_missing(self) -> &'static str {
        match self {
            TargetRole::Edit => {
                "The Studio plugin is not connected. Make sure Studio is open \
                 with the MCP plugin enabled."
            }
            TargetRole::Server => {
                "No play-mode server is connected. Start play mode first with \
                 start_stop_play (mode start_play or run_server)."
            }
            TargetRole::Client => {
                "No play-mode client is connected. Start play mode first with \
                 start_stop_play (mode start_play). Note that run_server mode \
                 has no client."
            }
            // Commands are never addressed to Legacy.
            TargetRole::Legacy => "Internal error: command addressed to the legacy role.",
        }
    }
}

fn parse_context(context: Option<&str>) -> Result<TargetRole, String> {
    match context {
        None | Some("edit") => Ok(TargetRole::Edit),
        Some("server") => Ok(TargetRole::Server),
        Some("client") => Ok(TargetRole::Client),
        Some(other) => Err(format!(
            "Invalid context '{other}': must be one of edit, server, or client"
        )),
    }
}

// Validates the run_code execution mode. The plugin treats any non-"execute"
// value as output mode, but we reject typos here so a misspelled mode does not
// silently fall back to capturing output.
fn validate_mode(mode: Option<&str>) -> Result<(), String> {
    match mode {
        None | Some("output") | Some("execute") => Ok(()),
        Some(other) => Err(format!("Invalid mode '{other}': must be output or execute")),
    }
}

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct ToolArguments {
    args: ToolArgumentValues,
    id: Option<Uuid>,
    // Defaults to Edit so commands proxied from older instances keep working.
    #[serde(default)]
    target: TargetRole,
    // Which Studio window ("placeId|placeName") the command is addressed to.
    // None means "let the port-owning server resolve it" (single connected
    // instance, or this command came from an older proxying server).
    #[serde(default)]
    instance: Option<String>,
}

// "0|Place1" -> "Place1 (placeId 0)" for human-readable errors and listings.
fn instance_display(id: &str) -> String {
    match id.split_once('|') {
        Some((place_id, name)) => format!("{name} (placeId {place_id})"),
        None => id.to_string(),
    }
}

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct RunCommandResponse {
    success: bool,
    response: String,
    id: Uuid,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct AckRequest {
    id: Uuid,
}

#[derive(Clone, Debug)]
struct QueuedTask {
    command: ToolArguments,
    attempts: u32,
}

struct InflightTask {
    task: QueuedTask,
    delivered_at: Instant,
}

// One connected Studio window, tracked by its role-tagged polls.
#[derive(Default)]
struct StudioInstance {
    last_poll: HashMap<TargetRole, Instant>,
}

impl StudioInstance {
    fn role_fresh(&self, role: TargetRole) -> bool {
        self.last_poll
            .get(&role)
            .is_some_and(|at| at.elapsed() < ROLE_FRESHNESS)
    }

    fn any_role_fresh(&self) -> bool {
        self.last_poll
            .values()
            .any(|at| at.elapsed() < ROLE_FRESHNESS)
    }

    fn seconds_since_poll(&self) -> Option<u64> {
        self.last_poll
            .values()
            .map(|at| at.elapsed().as_secs())
            .min()
    }
}

// Forget Studio windows that have not polled for this long.
const INSTANCE_PRUNE_AFTER: Duration = Duration::from_secs(600);

pub struct AppState {
    process_queue: VecDeque<QueuedTask>,
    // Commands handed to a long poll but not yet acknowledged by the plugin.
    inflight: HashMap<Uuid, InflightTask>,
    output_map: HashMap<Uuid, mpsc::UnboundedSender<Result<String>>>,
    // Connected Studio windows keyed by "placeId|placeName".
    instances: HashMap<String, StudioInstance>,
    waiter: watch::Receiver<()>,
    trigger: watch::Sender<()>,
}
pub type PackedState = Arc<Mutex<AppState>>;

impl AppState {
    pub fn new() -> Self {
        let (trigger, waiter) = watch::channel(());
        Self {
            process_queue: VecDeque::new(),
            inflight: HashMap::new(),
            output_map: HashMap::new(),
            instances: HashMap::new(),
            waiter,
            trigger,
        }
    }

    fn note_poll(&mut self, instance: &str, role: TargetRole) {
        // Legacy polls carry no role or instance and must not register as a
        // connected Studio (they come from plugins predating this protocol).
        if role == TargetRole::Legacy {
            return;
        }
        self.instances
            .entry(instance.to_string())
            .or_default()
            .last_poll
            .insert(role, Instant::now());
        self.instances.retain(|_, inst| {
            inst.seconds_since_poll().unwrap_or(u64::MAX) < INSTANCE_PRUNE_AFTER.as_secs()
        });
    }

    fn role_fresh(&self, instance: &str, role: TargetRole) -> bool {
        self.instances
            .get(instance)
            .is_some_and(|inst| inst.role_fresh(role))
    }

    fn any_role_fresh(&self, instance: &str) -> bool {
        self.instances
            .get(instance)
            .is_some_and(|inst| inst.any_role_fresh())
    }

    fn poll_status(&self, instance: Option<&str>, role: TargetRole) -> String {
        let Some(instance) = instance else {
            return "the command had no Studio instance attached".to_string();
        };
        match self
            .instances
            .get(instance)
            .and_then(|inst| inst.last_poll.get(&role))
        {
            Some(at) => format!(
                "last poll from the {role:?} DataModel of {} was {}s ago",
                instance_display(instance),
                at.elapsed().as_secs()
            ),
            None => format!(
                "the {role:?} DataModel of {} has not connected yet",
                instance_display(instance)
            ),
        }
    }

    fn fresh_instance_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .instances
            .iter()
            .filter(|(_, inst)| inst.any_role_fresh())
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
    }

    // Picks the Studio window to address when the caller has not selected one:
    // unambiguous only when exactly one is connected.
    fn resolve_auto_instance(&self) -> Result<String, String> {
        let fresh = self.fresh_instance_ids();
        match fresh.len() {
            0 => Err(
                "No Roblox Studio instance is connected. Make sure Studio is open \
                 with the MCP plugin enabled."
                    .to_string(),
            ),
            1 => Ok(fresh.into_iter().next().expect("len checked")),
            _ => {
                let list = fresh
                    .iter()
                    .map(|id| format!("- {}", instance_display(id)))
                    .collect::<Vec<_>>()
                    .join("\n");
                Err(format!(
                    "Multiple Roblox Studio instances are connected:\n{list}\n\
                     Call select_studio_instance with the place name or placeId to choose \
                     which one to operate on."
                ))
            }
        }
    }
}

impl ToolArguments {
    fn new(args: ToolArgumentValues, target: TargetRole, instance: Option<String>) -> (Self, Uuid) {
        Self {
            args,
            id: None,
            target,
            instance,
        }
        .with_id()
    }
    fn with_id(self) -> (Self, Uuid) {
        let id = Uuid::new_v4();
        (
            Self {
                id: Some(id),
                ..self
            },
            id,
        )
    }
}
#[derive(Clone)]
pub struct RBXStudioServer {
    state: PackedState,
    // Which Studio window this MCP client is working on. Per server process,
    // so different MCP clients can drive different Studio windows.
    selected_instance: Arc<Mutex<Option<String>>>,
    tool_router: ToolRouter<Self>,
}

#[tool_handler]
impl ServerHandler for RBXStudioServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            protocol_version: ProtocolVersion::LATEST,
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation {
                name: "Roblox_Studio".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
                title: Some("Roblox Studio MCP Server".to_string()),
                icons: None,
                website_url: None,
            },
            instructions: Some(
                "If several Roblox Studio windows are open, tools fail with a list of instances until one is chosen: call list_studio_instances, then select_studio_instance (by place name or placeId). A single open window is used automatically.
Be aware of the current studio mode before using tools; infer it from context or get_studio_mode.
Use run_code to query or change the place. It accepts context=edit|server|client; server/client run inside the live play session. run_code_from_file does the same but reads the script from a file path on the server machine instead of an inline string.
Prefer start_stop_play over run_script_in_play_mode; the latter is only for one-shot unit-test code on the server DataModel and resets the session to stop afterwards.

End-to-end play testing (like a real player):
1. start_stop_play mode=start_play, then wait_for the character: condition='local p = game.Players.LocalPlayer; return p and p.Character ~= nil'.
2. See the game with take_screenshot (full viewport, or ui_path to crop one UI element, isolate=true to hide other UI, park_mouse=true to keep hover tooltips out; save_to_file=true returns a local file path instead of inline image content). Use set_camera (frame target_path=... auto-fits an object; or set/look_at, then restore) to look at a specific 3D area first.
3. Find what to interact with: find_ui (search by text/name/class — returns paths, rects, and covered_by when something overlaps), get_ui_tree (full hierarchy), list_prompts (nearby ProximityPrompts with key and hold duration). Then interact: click_ui (path or x/y; fails naming the covering element if a popup would swallow the click — dismiss it or force=true), click_object (3D Parts/Models by workspace path), mouse_drag (aiming, sliders, drag-and-drop; auto-handles locked-cursor camera drags), mouse_move (hover), send_key (W/A/S/D, Space, action=press with duration to hold; triggers in-range ProximityPrompts), send_text (TextBoxes), control_character (move_to/walk/jump/get_state). For timing-sensitive combos run several steps in one input_sequence call.
4. Verify outcomes with wait_for + take_screenshot + get_console_output (pass since_seq=last_seq from the previous call for only-new entries; level=error to filter) and get_errors (script errors with stack traces, check context=server and context=client) instead of sleeping blindly.
5. start_stop_play mode=stop when done.
Input and screenshots need the Studio window visible: tools restore a minimized/covered window automatically and retry once, and studio_window (status/restore) does it explicitly.
COORDINATES: screenshot images are DPI-scaled — image pixels are NOT viewport coordinates. Click by element path or get_ui_tree/find_ui rects; to click something only seen in an image, scale by (viewport size / image size) from the screenshot metadata.
A focused TextBox swallows key input until released.
"
                    .to_string(),
            ),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct RunCode {
    #[schemars(description = "Code to run")]
    command: String,
    #[schemars(
        description = "Where to run the code: edit (default), server, or client. server/client require play mode to be running (see start_stop_play)."
    )]
    context: Option<String>,
    #[schemars(
        description = "Execution mode. output (default): print/warn/error are captured and returned together with any returned results. execute: run the code directly without overriding its environment (no getfenv/setfenv) and return no captured output — for applying changes or running a script where you don't need the printed output (prints still reach the console, read them with get_console_output)."
    )]
    mode: Option<String>,
    #[schemars(
        description = "In output mode, cap the returned output to this many lines (the last N lines are kept, earlier ones noted as omitted). Omit for no limit."
    )]
    max_lines: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct RunCodeFromFile {
    #[schemars(
        description = "Path to a Luau script file (.luau/.lua) on the machine running this MCP server — the same machine as Studio. Absolute paths are most reliable; relative paths resolve from the server's working directory."
    )]
    path: String,
    #[schemars(
        description = "Where to run the code: edit (default), server, or client. server/client require play mode to be running (see start_stop_play)."
    )]
    context: Option<String>,
    #[schemars(
        description = "Execution mode: output (default, captures and returns output) or execute (run directly, no getfenv/setfenv, no captured output). See run_code."
    )]
    mode: Option<String>,
    #[schemars(
        description = "In output mode, cap the returned output to this many lines (the last N are kept). Omit for no limit."
    )]
    max_lines: Option<u32>,
}
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct InsertModel {
    #[schemars(description = "Query to search for the model")]
    query: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct GetConsoleOutput {
    #[schemars(
        description = "Which DataModel's console to read: edit (default), server, or client. server/client require play mode to be running."
    )]
    context: Option<String>,
    #[schemars(
        description = "Only return entries newer than this sequence number (use last_seq from the previous call) — incremental reading instead of re-fetching everything."
    )]
    since_seq: Option<u64>,
    #[schemars(
        description = "Filter by level: output, info, warning, or error. Omit for all levels."
    )]
    level: Option<String>,
    #[schemars(description = "Maximum entries returned, newest kept. Defaults to 100, max 500.")]
    limit: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct GetErrors {
    #[schemars(
        description = "Which DataModel's script errors to read: edit (default), server, or client. Game code errors usually live on server or client."
    )]
    context: Option<String>,
    #[schemars(
        description = "Only return errors newer than this sequence number (use last_seq from the previous call)."
    )]
    since_seq: Option<u64>,
    #[schemars(description = "Maximum errors returned, newest kept. Defaults to 50, max 200.")]
    limit: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct GetStudioMode {}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct StartStopPlay {
    #[schemars(
        description = "Mode to start or stop, must be start_play, stop, or run_server. Don't use run_server unless you are sure no client/player is needed."
    )]
    mode: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct RunScriptInPlayMode {
    #[schemars(description = "Code to run")]
    code: String,
    #[schemars(description = "Timeout in seconds, defaults to 100 seconds")]
    timeout: Option<u32>,
    #[schemars(description = "Mode to run in, must be start_play or run_server")]
    mode: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct TakeScreenshot {
    #[schemars(
        description = "Optional UI path to capture just one element (e.g. 'ShopGui.Frame' relative to PlayerGui during play, StarterGui otherwise). Omit for the full viewport."
    )]
    ui_path: Option<String>,
    #[schemars(
        description = "When capturing a UI element, hide all other ScreenGuis during the capture so the element stands alone."
    )]
    isolate: Option<bool>,
    #[schemars(
        description = "Longest output dimension in pixels; larger captures are downscaled. Defaults to 1280."
    )]
    max_dimension: Option<u32>,
    #[schemars(description = "Output format: png (default) or jpeg.")]
    format: Option<String>,
    #[schemars(
        description = "Move the pointer to a screen corner before capturing so hover tooltips don't pollute the image. Defaults to false (the pointer state may be part of what you're verifying)."
    )]
    park_mouse: Option<bool>,
    #[schemars(
        description = "If true, save the encoded screenshot to a local temp file and return its path instead of returning image content directly. Defaults to false."
    )]
    save_to_file: Option<bool>,
}

// Internal commands used by take_screenshot; not exposed as MCP tools.
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct TakeScreenshotCapture {
    ui_path: Option<String>,
    isolate: Option<bool>,
    park_mouse: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Copy)]
struct PixelRect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct TakeScreenshotRead {
    content_id: String,
    viewport_w: f64,
    viewport_h: f64,
    rect: Option<PixelRect>,
}

#[derive(Debug, Deserialize)]
struct CaptureViewport {
    w: f64,
    h: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CaptureReply {
    content_id: String,
    viewport: CaptureViewport,
    rect: Option<PixelRect>,
}

#[derive(Debug, Deserialize)]
struct ReadReply {
    width: u32,
    height: u32,
    pixels: String,
}

struct EncodedScreenshot {
    bytes: Vec<u8>,
    mime: String,
    width: u32,
    height: u32,
}

enum ScreenshotToolOutput {
    Inline {
        data: String,
        mime: String,
        meta: String,
    },
    File {
        meta: String,
    },
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct GetUiTree {
    #[schemars(
        description = "Root to inspect, e.g. 'ShopGui' or 'game.StarterGui'. Defaults to PlayerGui during play, StarterGui otherwise."
    )]
    root: Option<String>,
    #[schemars(description = "How many levels deep to descend. Defaults to 6.")]
    max_depth: Option<u32>,
    #[schemars(
        description = "Include invisible elements and disabled ScreenGuis. Defaults to false."
    )]
    include_invisible: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct ClickUi {
    #[schemars(
        description = "UI element to click at its center, e.g. 'ShopGui.MainFrame.BuyButton' (relative to PlayerGui). Alternative to x/y."
    )]
    path: Option<String>,
    #[schemars(
        description = "Viewport x coordinate (same space as get_ui_tree rects). Used when no path is given."
    )]
    x: Option<f64>,
    #[schemars(description = "Viewport y coordinate. Used when no path is given.")]
    y: Option<f64>,
    #[schemars(description = "Mouse button: left (default), right, or middle.")]
    button: Option<String>,
    #[schemars(description = "click (default; press and release), down, or up.")]
    action: Option<String>,
    #[schemars(
        description = "Send the click even when another UI element (popup, overlay) covers the target and would receive it instead."
    )]
    force: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct FindUi {
    #[schemars(
        description = "Case-insensitive substring to match against element text (TextLabel/TextButton/TextBox)."
    )]
    text: Option<String>,
    #[schemars(description = "Case-insensitive substring to match against instance names.")]
    name: Option<String>,
    #[schemars(
        description = "Class filter with IsA semantics, e.g. TextButton, GuiButton (matches Text+Image buttons), TextBox."
    )]
    class: Option<String>,
    #[schemars(
        description = "Root to search under (PlayerGui-relative path). Defaults to the whole PlayerGui (StarterGui outside play)."
    )]
    root: Option<String>,
    #[schemars(
        description = "Also return elements that are not currently on screen (invisible, zero-size, disabled gui, or outside the viewport). Defaults to false."
    )]
    include_offscreen: Option<bool>,
    #[schemars(description = "Maximum matches returned. Defaults to 20, max 100.")]
    limit: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct ListPrompts {
    #[schemars(
        description = "Only prompts within this many studs of the character (camera outside play). Defaults to 100."
    )]
    max_distance: Option<f64>,
    #[schemars(description = "Maximum prompts returned, nearest first. Defaults to 20, max 100.")]
    limit: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct SendKey {
    #[schemars(description = "Enum.KeyCode name, e.g. W, A, S, D, Space, E, Return, LeftShift.")]
    key: String,
    #[schemars(
        description = "tap (default; press then release), press (hold down; releases after duration if given), or release."
    )]
    action: Option<String>,
    #[schemars(
        description = "Seconds to hold the key for tap/press (max 30). E.g. hold W for 2 seconds to walk forward."
    )]
    duration: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct SendText {
    #[schemars(description = "Text to type into the focused TextBox.")]
    text: String,
    #[schemars(
        description = "TextBox to focus first, e.g. 'ShopGui.SearchBox' (relative to PlayerGui)."
    )]
    textbox_path: Option<String>,
    #[schemars(
        description = "Press Enter after typing (ReleaseFocus with enterPressed=true). Defaults to false."
    )]
    submit: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct ControlCharacter {
    #[schemars(
        description = "move_to (x,y,z world position), walk (x,z direction for duration seconds), jump, stop, or get_state."
    )]
    action: String,
    x: Option<f64>,
    y: Option<f64>,
    z: Option<f64>,
    #[schemars(
        description = "Seconds: timeout for move_to (default 15), walk duration (default 1). Max 60."
    )]
    duration: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct MouseMove {
    #[schemars(
        description = "UI element whose center to move the pointer to, e.g. 'ShopGui.ItemFrame' (relative to PlayerGui). Alternative to x/y."
    )]
    path: Option<String>,
    #[schemars(description = "Viewport x coordinate (same space as get_ui_tree rects).")]
    x: Option<f64>,
    #[schemars(description = "Viewport y coordinate.")]
    y: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct MouseDrag {
    #[schemars(
        description = "UI element to start the drag from (its center). Alternative to from_x/from_y."
    )]
    from_path: Option<String>,
    #[schemars(description = "Drag start viewport x coordinate.")]
    from_x: Option<f64>,
    #[schemars(description = "Drag start viewport y coordinate.")]
    from_y: Option<f64>,
    #[schemars(
        description = "UI element to end the drag on (its center). Alternative to to_x/to_y."
    )]
    to_path: Option<String>,
    #[schemars(description = "Drag end viewport x coordinate.")]
    to_x: Option<f64>,
    #[schemars(description = "Drag end viewport y coordinate.")]
    to_y: Option<f64>,
    #[schemars(
        description = "Mouse button held during the drag: left (default), right, middle, or none (pointer sweep without holding — for hover)."
    )]
    button: Option<String>,
    #[schemars(description = "Seconds the drag takes from start to end. Defaults to 0.5, max 10.")]
    duration: Option<f64>,
    #[schemars(
        description = "Number of intermediate move events. Defaults to about 60 per second of duration."
    )]
    steps: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct ClickObject {
    #[schemars(
        description = "Workspace object to click (Part or Model), e.g. 'Shop.Door' or 'Workspace.Ball1'. Relative paths resolve under Workspace."
    )]
    path: String,
    #[schemars(description = "Mouse button: left (default), right, or middle.")]
    button: Option<String>,
    #[schemars(description = "click (default; press and release), down, or up.")]
    action: Option<String>,
    #[schemars(
        description = "Click the object's screen position even when something else is in front of it."
    )]
    force: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct SetCamera {
    #[schemars(
        description = "set (place the camera at x/y/z, optionally aimed at a target), look_at (keep position, aim at a target), restore (put the original camera back), or get (read the current camera)."
    )]
    action: String,
    #[schemars(description = "Camera world x position (for set).")]
    x: Option<f64>,
    #[schemars(description = "Camera world y position (for set).")]
    y: Option<f64>,
    #[schemars(description = "Camera world z position (for set).")]
    z: Option<f64>,
    #[schemars(
        description = "Workspace object to aim at, e.g. 'Arena.Ball1'. Alternative to target_x/y/z."
    )]
    target_path: Option<String>,
    #[schemars(description = "World x to aim at.")]
    target_x: Option<f64>,
    #[schemars(description = "World y to aim at.")]
    target_y: Option<f64>,
    #[schemars(description = "World z to aim at.")]
    target_z: Option<f64>,
    #[schemars(description = "Field of view in degrees (1-120).")]
    fov: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct InputStep {
    #[schemars(
        description = "What this step does: click, click_object, drag, move, key, text, or wait."
    )]
    action: String,
    #[schemars(
        description = "Target path: UI element for click/move, workspace object for click_object."
    )]
    path: Option<String>,
    #[schemars(description = "Viewport x for click/move.")]
    x: Option<f64>,
    #[schemars(description = "Viewport y for click/move.")]
    y: Option<f64>,
    #[schemars(description = "Drag start: UI path.")]
    from_path: Option<String>,
    #[schemars(description = "Drag start viewport x.")]
    from_x: Option<f64>,
    #[schemars(description = "Drag start viewport y.")]
    from_y: Option<f64>,
    #[schemars(description = "Drag end: UI path.")]
    to_path: Option<String>,
    #[schemars(description = "Drag end viewport x.")]
    to_x: Option<f64>,
    #[schemars(description = "Drag end viewport y.")]
    to_y: Option<f64>,
    #[schemars(description = "Mouse button for click/click_object/drag steps.")]
    button: Option<String>,
    #[schemars(
        description = "Sub-mode: click steps accept click/down/up, key steps accept tap/press/release."
    )]
    mode: Option<String>,
    #[schemars(description = "Enum.KeyCode name for key steps, e.g. W, Space, Return.")]
    key: Option<String>,
    #[schemars(description = "Hold time for key steps / drag time for drag steps, in seconds.")]
    duration: Option<f64>,
    #[schemars(description = "Text for text steps.")]
    text: Option<String>,
    #[schemars(description = "TextBox to focus first for text steps.")]
    textbox_path: Option<String>,
    #[schemars(description = "Press Enter after typing for text steps.")]
    submit: Option<bool>,
    #[schemars(description = "Seconds to pause for wait steps (max 10).")]
    seconds: Option<f64>,
    #[schemars(description = "click_object: click even when the object is occluded.")]
    force: Option<bool>,
    #[schemars(description = "Number of intermediate move events for drag steps.")]
    steps: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct InputSequence {
    #[schemars(
        description = "Steps executed in order on the play-mode client. Execution stops at the first failing step."
    )]
    steps: Vec<InputStep>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct WaitFor {
    #[schemars(
        description = "Luau code whose first returned value is checked for truthiness, e.g. 'return game.Players.LocalPlayer.Character ~= nil'."
    )]
    condition: String,
    #[schemars(description = "Seconds before giving up. Defaults to 30, max 600.")]
    timeout: Option<f64>,
    #[schemars(description = "Seconds between checks. Defaults to 0.25.")]
    poll_interval: Option<f64>,
    #[schemars(description = "Where to evaluate: client (default during play), server, or edit.")]
    context: Option<String>,
}

// Server-local tools (no plugin round trip).
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct ListStudioInstances {}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct StudioWindow {
    #[schemars(
        description = "status (list Roblox Studio windows: title, minimized, foreground), or restore (un-minimize and bring to the foreground so rendering resumes; focus is an alias)."
    )]
    action: String,
    #[schemars(
        description = "Substring of the window title to pick when several Studio windows are open. Defaults to the selected instance's window, or the only open one."
    )]
    title: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct SelectStudioInstance {
    #[schemars(
        description = "Which Studio window to operate on: a place name (case-insensitive substring), a placeId, or the full instance id from list_studio_instances. Pass 'auto' to clear the selection."
    )]
    instance: String,
}

// One row of GET /instances, also consumed by the MCP tools via HTTP so that
// secondary (proxying) server processes see the port owner's data.
#[derive(Debug, Serialize, Deserialize)]
struct InstanceSummary {
    id: String,
    name: String,
    place_id: String,
    // Roles polling within the freshness window, e.g. ["edit", "server"].
    connected_roles: Vec<String>,
    seconds_since_poll: u64,
}

async fn fetch_instances() -> Result<Vec<InstanceSummary>, String> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(3))
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {e}"))?;
    let response = client
        .get(format!("http://127.0.0.1:{STUDIO_PLUGIN_PORT}/instances"))
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .map_err(|e| {
            format!("Could not reach the MCP HTTP server on port {STUDIO_PLUGIN_PORT}: {e}")
        })?;
    response
        .json::<Vec<InstanceSummary>>()
        .await
        .map_err(|e| format!("Unexpected /instances response: {e}"))
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
enum ToolArgumentValues {
    RunCode(RunCode),
    InsertModel(InsertModel),
    GetConsoleOutput(GetConsoleOutput),
    StartStopPlay(StartStopPlay),
    RunScriptInPlayMode(RunScriptInPlayMode),
    GetStudioMode(GetStudioMode),
    TakeScreenshotCapture(TakeScreenshotCapture),
    TakeScreenshotRead(TakeScreenshotRead),
    GetUiTree(GetUiTree),
    ClickUi(ClickUi),
    FindUi(FindUi),
    ListPrompts(ListPrompts),
    GetErrors(GetErrors),
    MouseMove(MouseMove),
    MouseDrag(MouseDrag),
    ClickObject(ClickObject),
    SetCamera(SetCamera),
    InputSequence(InputSequence),
    SendKey(SendKey),
    SendText(SendText),
    ControlCharacter(ControlCharacter),
    WaitFor(WaitFor),
}

// How long the MCP side waits for Studio before giving up on a command.
// Without a bound here, a command lost to a dead connection would hang the
// tool call forever.
fn execution_timeout(args: &ToolArgumentValues) -> Duration {
    match args {
        ToolArgumentValues::RunScriptInPlayMode(args) => {
            Duration::from_secs(u64::from(args.timeout.unwrap_or(100))) + PLAY_MODE_TIMEOUT_GRACE
        }
        // Capture either completes within its internal 5s race or fails fast.
        ToolArgumentValues::TakeScreenshotCapture(_) => Duration::from_secs(30),
        // Reading and base64-encoding a large capture takes a few seconds.
        ToolArgumentValues::TakeScreenshotRead(_) => Duration::from_secs(90),
        ToolArgumentValues::SendKey(args) => {
            Duration::from_secs_f64(args.duration.unwrap_or(0.0).clamp(0.0, 30.0))
                + Duration::from_secs(30)
        }
        ToolArgumentValues::ControlCharacter(args) => {
            Duration::from_secs_f64(args.duration.unwrap_or(15.0).clamp(0.0, 60.0))
                + Duration::from_secs(30)
        }
        ToolArgumentValues::WaitFor(args) => {
            Duration::from_secs_f64(args.timeout.unwrap_or(30.0).clamp(0.1, 600.0))
                + PLAY_MODE_TIMEOUT_GRACE
        }
        ToolArgumentValues::MouseDrag(args) => {
            Duration::from_secs_f64(args.duration.unwrap_or(0.5).clamp(0.05, 10.0))
                + Duration::from_secs(30)
        }
        // Mirrored in the plugin's executionTimeout(): one second of overhead
        // per step plus its waits and holds.
        ToolArgumentValues::InputSequence(args) => {
            let total: f64 = args
                .steps
                .iter()
                .map(|step| {
                    1.0 + step.seconds.unwrap_or(0.0).clamp(0.0, 10.0)
                        + step.duration.unwrap_or(0.0).clamp(0.0, 30.0)
                })
                .sum();
            Duration::from_secs_f64(total) + PLAY_MODE_TIMEOUT_GRACE
        }
        _ => DEFAULT_TOOL_TIMEOUT,
    }
}

// Decodes the plugin's raw RGBA payload and encodes it as PNG or JPEG,
// downscaling to max_dimension. CPU bound; run on a blocking thread.
fn encode_screenshot(
    read: ReadReply,
    max_dimension: u32,
    format: &str,
) -> Result<EncodedScreenshot, String> {
    use base64::Engine;

    let raw = base64::engine::general_purpose::STANDARD
        .decode(read.pixels.as_bytes())
        .map_err(|e| format!("Invalid base64 pixel data from Studio: {e}"))?;
    let image = image::RgbaImage::from_raw(read.width, read.height, raw).ok_or(format!(
        "Pixel data does not match reported size {}x{}",
        read.width, read.height
    ))?;

    encode_rgba(image, max_dimension, format)
}

// Downscales to max_dimension and encodes as PNG or JPEG. CPU bound.
fn encode_rgba(
    image: image::RgbaImage,
    max_dimension: u32,
    format: &str,
) -> Result<EncodedScreenshot, String> {
    let (width, height) = image.dimensions();
    let longest = width.max(height);
    let image = if longest > max_dimension {
        let scale = f64::from(max_dimension) / f64::from(longest);
        let new_width = ((f64::from(width) * scale).round() as u32).max(1);
        let new_height = ((f64::from(height) * scale).round() as u32).max(1);
        image::imageops::resize(
            &image,
            new_width,
            new_height,
            image::imageops::FilterType::Triangle,
        )
    } else {
        image
    };
    let (out_width, out_height) = image.dimensions();

    let mut encoded: Vec<u8> = Vec::new();
    let mime = if format == "jpeg" {
        let rgb = image::DynamicImage::ImageRgba8(image).to_rgb8();
        let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, 85);
        encoder
            .encode_image(&rgb)
            .map_err(|e| format!("JPEG encoding failed: {e}"))?;
        "image/jpeg"
    } else {
        image::DynamicImage::ImageRgba8(image)
            .write_to(
                &mut std::io::Cursor::new(&mut encoded),
                image::ImageFormat::Png,
            )
            .map_err(|e| format!("PNG encoding failed: {e}"))?;
        "image/png"
    };

    Ok(EncodedScreenshot {
        bytes: encoded,
        mime: mime.to_string(),
        width: out_width,
        height: out_height,
    })
}

fn save_screenshot_file(encoded: &EncodedScreenshot, format: &str) -> Result<String, String> {
    let extension = if format == "jpeg" { "jpg" } else { "png" };
    let dir = std::env::temp_dir().join("roblox-studio-mcp-screenshots");
    std::fs::create_dir_all(&dir).map_err(|e| {
        format!(
            "Failed to create screenshot output directory {}: {e}",
            dir.display()
        )
    })?;
    let path = dir.join(format!("screenshot-{}.{}", Uuid::new_v4(), extension));
    std::fs::write(&path, &encoded.bytes)
        .map_err(|e| format!("Failed to write screenshot file {}: {e}", path.display()))?;
    Ok(path.to_string_lossy().into_owned())
}

fn finish_screenshot_output(
    encoded: EncodedScreenshot,
    mut meta: serde_json::Value,
    format: &str,
    save_to_file: bool,
) -> Result<ScreenshotToolOutput, String> {
    if let Some(obj) = meta.as_object_mut() {
        obj.insert("width".to_string(), serde_json::json!(encoded.width));
        obj.insert("height".to_string(), serde_json::json!(encoded.height));
        obj.insert("mime".to_string(), serde_json::json!(encoded.mime.clone()));
    }

    if save_to_file {
        let path = save_screenshot_file(&encoded, format)?;
        if let Some(obj) = meta.as_object_mut() {
            obj.insert("delivery".to_string(), serde_json::json!("file"));
            obj.insert("path".to_string(), serde_json::json!(path));
        }
        return Ok(ScreenshotToolOutput::File {
            meta: meta.to_string(),
        });
    }

    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD.encode(&encoded.bytes);
    if let Some(obj) = meta.as_object_mut() {
        obj.insert("delivery".to_string(), serde_json::json!("inline_image"));
    }
    Ok(ScreenshotToolOutput::Inline {
        data,
        mime: encoded.mime,
        meta: meta.to_string(),
    })
}

#[tool_router]
impl RBXStudioServer {
    pub fn new(state: PackedState) -> Self {
        Self {
            state,
            selected_instance: Arc::new(Mutex::new(None)),
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        description = "Runs a command in Roblox Studio and returns the printed output. Can be used to both make changes and retrieve information. Use context=server or context=client to run the code inside a running play session (e.g. to inspect PlayerGui or fire client-side behavior)."
    )]
    async fn run_code(
        &self,
        Parameters(args): Parameters<RunCode>,
    ) -> Result<CallToolResult, ErrorData> {
        let target = match parse_context(args.context.as_deref()) {
            Ok(target) => target,
            Err(msg) => return Ok(CallToolResult::error(vec![Content::text(msg)])),
        };
        if let Err(msg) = validate_mode(args.mode.as_deref()) {
            return Ok(CallToolResult::error(vec![Content::text(msg)]));
        }
        self.generic_tool_run_on(ToolArgumentValues::RunCode(args), target)
            .await
    }

    #[tool(
        description = "Reads a Luau script from a file on disk (the machine running this MCP server, same as Studio) and runs it in Roblox Studio, returning the printed output. \
        Like run_code but the code comes from a file path instead of an inline string — useful for large scripts or running a saved .luau file without pasting its contents. \
        Use context=server or context=client to run inside a running play session."
    )]
    async fn run_code_from_file(
        &self,
        Parameters(args): Parameters<RunCodeFromFile>,
    ) -> Result<CallToolResult, ErrorData> {
        let target = match parse_context(args.context.as_deref()) {
            Ok(target) => target,
            Err(msg) => return Ok(CallToolResult::error(vec![Content::text(msg)])),
        };
        if let Err(msg) = validate_mode(args.mode.as_deref()) {
            return Ok(CallToolResult::error(vec![Content::text(msg)]));
        }
        let command = match tokio::fs::read_to_string(&args.path).await {
            Ok(contents) => contents,
            Err(err) => {
                return Ok(CallToolResult::error(vec![Content::text(format!(
                    "Could not read script file {:?}: {err}",
                    args.path
                ))]));
            }
        };
        if command.trim().is_empty() {
            return Ok(CallToolResult::error(vec![Content::text(format!(
                "Script file {:?} is empty.",
                args.path
            ))]));
        }
        self.generic_tool_run_on(
            ToolArgumentValues::RunCode(RunCode {
                command,
                context: args.context,
                mode: args.mode,
                max_lines: args.max_lines,
            }),
            target,
        )
        .await
    }

    #[tool(
        description = "Inserts a model from the Roblox marketplace into the workspace. Returns the inserted model name."
    )]
    async fn insert_model(
        &self,
        Parameters(args): Parameters<InsertModel>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::InsertModel(args))
            .await
    }

    #[tool(
        description = "Get console output from Roblox Studio as { entries: [{seq, ts, level, message}], last_seq, dropped }. \
        Use context=server or context=client to read logs captured inside a running play session. \
        For incremental reading pass since_seq=last_seq from the previous call; level=error narrows to errors. \
        For stack traces of script errors use get_errors instead."
    )]
    async fn get_console_output(
        &self,
        Parameters(args): Parameters<GetConsoleOutput>,
    ) -> Result<CallToolResult, ErrorData> {
        let target = match parse_context(args.context.as_deref()) {
            Ok(target) => target,
            Err(msg) => return Ok(CallToolResult::error(vec![Content::text(msg)])),
        };
        self.generic_tool_run_on(ToolArgumentValues::GetConsoleOutput(args), target)
            .await
    }

    #[tool(
        description = "Get script errors with full stack traces and the erroring script's path, as { errors: [{seq, ts, message, stack, script_path}], last_seq }. \
        The fast way to check 'did anything break?' in an end-to-end test — check both context=server and context=client after exercising a feature. \
        Pass since_seq=last_seq from the previous call to only see new errors."
    )]
    async fn get_errors(
        &self,
        Parameters(args): Parameters<GetErrors>,
    ) -> Result<CallToolResult, ErrorData> {
        let target = match parse_context(args.context.as_deref()) {
            Ok(target) => target,
            Err(msg) => return Ok(CallToolResult::error(vec![Content::text(msg)])),
        };
        self.generic_tool_run_on(ToolArgumentValues::GetErrors(args), target)
            .await
    }

    #[tool(
        description = "Start or stop play mode or run the server, Don't enter run_server mode unless you are sure no client/player is needed."
    )]
    async fn start_stop_play(
        &self,
        Parameters(args): Parameters<StartStopPlay>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::StartStopPlay(args))
            .await
    }

    #[tool(
        description = "Run a script in play mode and automatically stop play after script finishes or timeout. Returns the output of the script.
        Result format: { success: boolean, value: string, error: string, logs: { level: string, message: string, ts: number }[], errors: { level: string, message: string, ts: number }[], duration: number, isTimeout: boolean }.
        - Prefer using start_stop_play tool instead run_script_in_play_mode, Only used run_script_in_play_mode to run one time unit test code on server datamodel.
        - After calling run_script_in_play_mode, the datamodel status will be reset to stop mode.
        - If It returns `StudioTestService: Previous call to start play session has not been completed`, call start_stop_play tool to stop play mode first then try it again."
    )]
    async fn run_script_in_play_mode(
        &self,
        Parameters(args): Parameters<RunScriptInPlayMode>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::RunScriptInPlayMode(args))
            .await
    }

    #[tool(
        description = "Get the current studio mode. Returns the studio mode. The result will be one of start_play, run_server, or stop."
    )]
    async fn get_studio_mode(
        &self,
        Parameters(args): Parameters<GetStudioMode>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::GetStudioMode(args))
            .await
    }

    #[tool(
        description = "Take a screenshot of what the game is rendering and return it as an image. \
        In play mode this captures the running game exactly as the player sees it (3D world plus all UI). \
        Use ui_path to capture a single ScreenGui or GuiObject cropped to its bounds (path relative to PlayerGui during play, e.g. 'ShopGui.MainFrame'); \
        add isolate=true to hide all other UI while capturing it. \
        Set save_to_file=true to save the screenshot to a local temp file and return its path instead of inline image content. \
        Requires the Studio window to be visible (not minimized)."
    )]
    async fn take_screenshot(
        &self,
        Parameters(args): Parameters<TakeScreenshot>,
    ) -> Result<CallToolResult, ErrorData> {
        match self.take_screenshot_impl(args).await {
            Ok(ScreenshotToolOutput::Inline { data, mime, meta }) => {
                Ok(CallToolResult::success(vec![
                    Content::image(data, mime),
                    Content::text(meta),
                ]))
            }
            Ok(ScreenshotToolOutput::File { meta }) => {
                Ok(CallToolResult::success(vec![Content::text(meta)]))
            }
            Err(message) => Ok(CallToolResult::error(vec![Content::text(message)])),
        }
    }

    async fn take_screenshot_impl(
        &self,
        args: TakeScreenshot,
    ) -> Result<ScreenshotToolOutput, String> {
        let format = match args.format.as_deref() {
            None | Some("png") => "png",
            Some("jpeg") | Some("jpg") => "jpeg",
            Some(other) => return Err(format!("Invalid format '{other}': must be png or jpeg")),
        };
        let max_dimension = args.max_dimension.unwrap_or(1280).clamp(64, 4096);
        let save_to_file = args.save_to_file.unwrap_or(false);

        match self.capture_via_engine(&args).await {
            Ok((read, mode, capture_role, viewport)) => {
                let encoded = tokio::task::spawn_blocking(move || {
                    encode_screenshot(read, max_dimension, format)
                })
                .await
                .map_err(|e| format!("Image encoding task failed: {e}"))??;

                let meta = serde_json::json!({
                    // Viewport size in the coordinate system used by
                    // get_ui_tree rects and click_ui positions. To click a
                    // pixel seen in this image, scale by viewport/image size.
                    "viewport": { "w": viewport.w, "h": viewport.h },
                    "studio_mode": mode,
                    "captured_on": format!("{capture_role:?}"),
                    "source": "CaptureService",
                    "ui_path": args.ui_path,
                    "isolate": args.isolate.unwrap_or(false),
                });

                finish_screenshot_output(encoded, meta, format, save_to_file)
            }
            Err(engine_error) => {
                // The in-engine path has a known failure mode (capture callback
                // never fires) and cannot work while Studio is not rendering.
                // Capture the Studio window at the OS level instead.
                let captured =
                    tokio::task::spawn_blocking(crate::os_capture::capture_studio_window)
                        .await
                        .map_err(|e| format!("OS capture task failed: {e}"))?
                        .map_err(|os_error| {
                            format!(
                                "In-engine capture failed: {engine_error}\n\
                                 OS window capture also failed: {os_error}"
                            )
                        })?;

                let title = captured.title.clone();
                let encoded = tokio::task::spawn_blocking(move || {
                    encode_rgba(captured.image, max_dimension, format)
                })
                .await
                .map_err(|e| format!("Image encoding task failed: {e}"))??;

                let meta = serde_json::json!({
                    "source": "os_window",
                    "window_title": title,
                    "note": "Fallback capture of the whole Studio window (includes Studio chrome; ui_path crop and viewport coordinates do not apply).",
                    "engine_error": engine_error,
                });

                finish_screenshot_output(encoded, meta, format, save_to_file)
            }
        }
    }

    // The DataModel that owns the rendered viewport: the client during play,
    // the server in run mode, edit otherwise. GlobalVariables only tracks
    // MCP-initiated sessions, so fall back to live poll freshness (covers
    // the user pressing Play manually). Returns the mode string as well.
    async fn rendering_role(
        &self,
        instance: Option<String>,
    ) -> Result<(String, TargetRole), String> {
        let mode = self
            .execute_on_instance(
                ToolArgumentValues::GetStudioMode(GetStudioMode {}),
                TargetRole::Edit,
                instance.clone(),
            )
            .await?;
        let role = match mode.trim() {
            "start_play" => TargetRole::Client,
            "run_server" => TargetRole::Server,
            _ => {
                let state = self.state.lock().await;
                let known = instance.as_deref().unwrap_or("default");
                if state.role_fresh(known, TargetRole::Client) {
                    TargetRole::Client
                } else if state.role_fresh(known, TargetRole::Server) {
                    TargetRole::Server
                } else {
                    TargetRole::Edit
                }
            }
        };
        Ok((mode.trim().to_string(), role))
    }

    // The in-engine screenshot path: capture on the rendering DataModel via
    // CaptureService, then read the pixels on the edit DataModel. Both steps
    // are pinned to the same Studio window, resolved once up front.
    async fn capture_via_engine(
        &self,
        args: &TakeScreenshot,
    ) -> Result<(ReadReply, String, TargetRole, CaptureViewport), String> {
        let instance = self.resolve_instance().await?;

        // Capture must run on the DataModel that renders.
        let (mode, capture_role) = self.rendering_role(instance.clone()).await?;

        let capture_json = self
            .execute_on_instance(
                ToolArgumentValues::TakeScreenshotCapture(TakeScreenshotCapture {
                    ui_path: args.ui_path.clone(),
                    isolate: args.isolate,
                    park_mouse: args.park_mouse,
                }),
                capture_role,
                instance.clone(),
            )
            .await
            .map_err(|e| {
                format!("Screenshot capture failed on the {capture_role:?} DataModel: {e}")
            })?;
        let capture: CaptureReply = serde_json::from_str(&capture_json)
            .map_err(|e| format!("Unexpected capture reply from Studio ({e}): {capture_json}"))?;

        // The temporary contentId is readable from the edit DataModel, which
        // talks to the MCP server directly over HTTP — so multi-MB pixel data
        // never crosses the client relay.
        let read_json = self
            .execute_on_instance(
                ToolArgumentValues::TakeScreenshotRead(TakeScreenshotRead {
                    content_id: capture.content_id,
                    viewport_w: capture.viewport.w,
                    viewport_h: capture.viewport.h,
                    rect: capture.rect,
                }),
                TargetRole::Edit,
                instance,
            )
            .await
            .map_err(|e| format!("Reading screenshot pixels failed: {e}"))?;
        let read: ReadReply = serde_json::from_str(&read_json)
            .map_err(|e| format!("Unexpected pixel reply from Studio: {e}"))?;

        Ok((read, mode, capture_role, capture.viewport))
    }

    #[tool(
        description = "Inspect the UI hierarchy as a JSON tree: names, classes, on-screen rects, text, and whether elements are clickable/editable. \
        During play this reads the live PlayerGui on the client — the primary way to find what to click. \
        Rects are [x, y, w, h] in viewport coordinates; pass a rect center directly to click_ui as x/y, or use the element path with click_ui."
    )]
    async fn get_ui_tree(
        &self,
        Parameters(args): Parameters<GetUiTree>,
    ) -> Result<CallToolResult, ErrorData> {
        let result = async {
            let instance = self.resolve_instance().await?;
            let target = self
                .play_aware_role(TargetRole::Edit, instance.clone())
                .await?;
            self.execute_on_instance(ToolArgumentValues::GetUiTree(args), target, instance)
                .await
        }
        .await;
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err)])),
        }
    }

    #[tool(
        description = "Click like a real player through the engine's input pipeline (GuiButton handlers, InputBegan, etc. all fire normally). \
        Target a UI element by path (clicked at its center) or an explicit viewport x/y position (e.g. to click the 3D world). \
        Path-targeted clicks fail with the covering element's name when a popup/overlay would receive the click instead (force=true clicks anyway). \
        Requires play mode (start_stop_play with start_play) and a visible Studio window. \
        Verify the effect afterwards with take_screenshot or get_ui_tree."
    )]
    async fn click_ui(
        &self,
        Parameters(args): Parameters<ClickUi>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(ToolArgumentValues::ClickUi(args), TargetRole::Client)
            .await
    }

    #[tool(
        description = "Find UI elements by text, name, or class without dumping the whole tree — the fast way to locate a button, popup, or TextBox in a real game's deep UI. \
        Returns path (feed it to click_ui/send_text directly), class, rect, text, clickable/editable flags, and covered_by when another element would swallow a click. \
        Only elements actually on screen are returned unless include_offscreen=true."
    )]
    async fn find_ui(
        &self,
        Parameters(args): Parameters<FindUi>,
    ) -> Result<CallToolResult, ErrorData> {
        let result = async {
            let instance = self.resolve_instance().await?;
            let target = self
                .play_aware_role(TargetRole::Edit, instance.clone())
                .await?;
            self.execute_on_instance(ToolArgumentValues::FindUi(args), target, instance)
                .await
        }
        .await;
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err)])),
        }
    }

    #[tool(
        description = "List nearby ProximityPrompts (the 'press E to interact' affordances): action text, key, hold duration, world position, distance, and whether the character is in range. \
        To trigger one, get in range (control_character move_to) and send_key with its key — for hold prompts use action=press with duration >= hold_duration."
    )]
    async fn list_prompts(
        &self,
        Parameters(args): Parameters<ListPrompts>,
    ) -> Result<CallToolResult, ErrorData> {
        let result = async {
            let instance = self.resolve_instance().await?;
            let target = self
                .play_aware_role(TargetRole::Server, instance.clone())
                .await?;
            self.execute_on_instance(ToolArgumentValues::ListPrompts(args), target, instance)
                .await
        }
        .await;
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err)])),
        }
    }

    #[tool(
        description = "Press keyboard keys like a real player: the default control scripts respond (W walks forward, Space jumps) and game code sees normal input events. \
        Use action=press with duration to hold a key (e.g. W for 2s to walk), or tap for a quick press. \
        Requires play mode and a visible Studio window."
    )]
    async fn send_key(
        &self,
        Parameters(args): Parameters<SendKey>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(ToolArgumentValues::SendKey(args), TargetRole::Client)
            .await
    }

    #[tool(
        description = "Type text into a TextBox like a real player. Give textbox_path to focus it first, set submit=true to press Enter after. \
        Returns the TextBox's resulting text for verification. Requires play mode and a visible Studio window."
    )]
    async fn send_text(
        &self,
        Parameters(args): Parameters<SendText>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(ToolArgumentValues::SendText(args), TargetRole::Client)
            .await
    }

    #[tool(
        description = "Move the mouse pointer like a real player without clicking — for hover effects (MouseEnter, tooltips) and for positioning before a click or drag. \
        Target a UI element by path or a viewport x/y. Requires play mode and a visible Studio window."
    )]
    async fn mouse_move(
        &self,
        Parameters(args): Parameters<MouseMove>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(ToolArgumentValues::MouseMove(args), TargetRole::Client)
            .await
    }

    #[tool(
        description = "Drag the mouse like a real player: button down at the start, a smooth stream of move events, button up at the end — for aiming (billiards-style), sliders, drag-and-drop, and swipes. \
        While the game locks the cursor (e.g. a right-button camera drag) movement is delivered as deltas automatically. \
        Points are viewport coordinates or UI paths. Requires play mode and a visible Studio window."
    )]
    async fn mouse_drag(
        &self,
        Parameters(args): Parameters<MouseDrag>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(ToolArgumentValues::MouseDrag(args), TargetRole::Client)
            .await
    }

    #[tool(
        description = "Click a 3D object in the workspace (Part or Model) like a real player: its position is projected to the screen and clicked through the real input pipeline, so ClickDetectors and raycast-based games respond normally. \
        Fails with an explanation if the object is off screen, hidden behind world geometry, or covered by 2D UI at that pixel (set_camera or move closer first; force=true clicks anyway). \
        Requires play mode and a visible Studio window."
    )]
    async fn click_object(
        &self,
        Parameters(args): Parameters<ClickObject>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(ToolArgumentValues::ClickObject(args), TargetRole::Client)
            .await
    }

    #[tool(
        description = "Position the camera for verification: action=set places it at x/y/z (optionally aimed at target_path or target_x/y/z), look_at aims the current position at a target, \
        frame auto-positions to fit a target object's whole bounding box in view (no coordinates needed), get reads the camera, restore puts the player's original camera back. \
        Use before take_screenshot to verify a specific 3D area, or before click_object/mouse_drag when the target is off screen. \
        Always restore when done so normal play input works again."
    )]
    async fn set_camera(
        &self,
        Parameters(args): Parameters<SetCamera>,
    ) -> Result<CallToolResult, ErrorData> {
        let result = async {
            let instance = self.resolve_instance().await?;
            let (_, role) = self.rendering_role(instance.clone()).await?;
            self.execute_on_instance(ToolArgumentValues::SetCamera(args), role, instance)
                .await
        }
        .await;
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err)])),
        }
    }

    #[tool(
        description = "Run a list of input steps in one call with precise timing — for combos that per-call latency would break: double clicks, hold-key-then-click, click-wait-click flows. \
        Steps: {action: click|click_object|drag|move|key|text|wait, ...same fields as the matching single tool, with mode carrying click/down/up or tap/press/release, and seconds for wait}. \
        Stops at the first failing step; returns per-step results. Requires play mode and a visible Studio window."
    )]
    async fn input_sequence(
        &self,
        Parameters(args): Parameters<InputSequence>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(ToolArgumentValues::InputSequence(args), TargetRole::Client)
            .await
    }

    #[tool(
        description = "Control the player character during play mode: move_to a world position (waits for arrival), walk in a direction, jump, stop, or get_state \
        (position, health, velocity, camera). For movement that must look like raw input, use send_key with WASD instead."
    )]
    async fn control_character(
        &self,
        Parameters(args): Parameters<ControlCharacter>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(
            ToolArgumentValues::ControlCharacter(args),
            TargetRole::Client,
        )
        .await
    }

    #[tool(
        description = "Wait until a Luau condition becomes truthy, polling at an interval — the reliable way to wait for game state in end-to-end tests \
        (character spawned, UI appeared, value changed) instead of guessing with sleeps. \
        Example: condition='local p = game.Players.LocalPlayer; return p and p.Character ~= nil'. \
        Returns { satisfied, elapsed, checks, value, last_error }."
    )]
    async fn wait_for(
        &self,
        Parameters(args): Parameters<WaitFor>,
    ) -> Result<CallToolResult, ErrorData> {
        let result = async {
            let instance = self.resolve_instance().await?;
            let target = match args.context.as_deref() {
                Some(_) => parse_context(args.context.as_deref())?,
                None => {
                    self.play_aware_role(TargetRole::Server, instance.clone())
                        .await?
                }
            };
            self.execute_on_instance(ToolArgumentValues::WaitFor(args), target, instance)
                .await
        }
        .await;
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err)])),
        }
    }

    #[tool(
        description = "List the Roblox Studio windows currently connected to this MCP server: place name, placeId, which DataModels are live (edit/server/client), and which window is selected. \
        When exactly one window is connected it is used automatically; with several open, call select_studio_instance to choose."
    )]
    async fn list_studio_instances(
        &self,
        Parameters(_args): Parameters<ListStudioInstances>,
    ) -> Result<CallToolResult, ErrorData> {
        match fetch_instances().await {
            Ok(instances) => {
                let selected = self.selected_instance.lock().await.clone();
                let body = serde_json::json!({
                    "instances": instances.iter().map(|inst| serde_json::json!({
                        "id": inst.id,
                        "name": inst.name,
                        "place_id": inst.place_id,
                        "connected_roles": inst.connected_roles,
                        "seconds_since_poll": inst.seconds_since_poll,
                        "selected": selected.as_deref() == Some(inst.id.as_str()),
                    })).collect::<Vec<_>>(),
                    "selection": selected.as_deref().map(instance_display),
                    "note": "A single connected instance is used automatically; otherwise pick one with select_studio_instance (by name or placeId).",
                });
                Ok(CallToolResult::success(vec![Content::text(
                    serde_json::to_string_pretty(&body).unwrap_or_default(),
                )]))
            }
            Err(message) => Ok(CallToolResult::error(vec![Content::text(message)])),
        }
    }

    #[tool(
        description = "Choose which open Roblox Studio window all subsequent tools operate on. Match by place name (case-insensitive substring), placeId, or the full instance id from list_studio_instances. \
        Pass 'auto' to clear the selection again (the single connected window is then used automatically). The selection is per MCP client."
    )]
    async fn select_studio_instance(
        &self,
        Parameters(args): Parameters<SelectStudioInstance>,
    ) -> Result<CallToolResult, ErrorData> {
        let query = args.instance.trim().to_string();
        if query.is_empty() || query.eq_ignore_ascii_case("auto") {
            *self.selected_instance.lock().await = None;
            return Ok(CallToolResult::success(vec![Content::text(
                "Selection cleared: the single connected Studio instance will be used automatically.",
            )]));
        }
        let instances = match fetch_instances().await {
            Ok(instances) => instances,
            Err(message) => return Ok(CallToolResult::error(vec![Content::text(message)])),
        };
        let connected: Vec<InstanceSummary> = instances
            .into_iter()
            .filter(|inst| !inst.connected_roles.is_empty())
            .collect();
        let query_lower = query.to_lowercase();
        let matches: Vec<&InstanceSummary> = connected
            .iter()
            .filter(|inst| {
                inst.id == query
                    || inst.place_id == query
                    || inst.name.to_lowercase().contains(&query_lower)
            })
            .collect();
        let describe_all = |list: &[&InstanceSummary]| {
            list.iter()
                .map(|inst| format!("- {}", instance_display(&inst.id)))
                .collect::<Vec<_>>()
                .join("\n")
        };
        match matches.len() {
            1 => {
                let chosen = matches[0].id.clone();
                let display = instance_display(&chosen);
                *self.selected_instance.lock().await = Some(chosen);
                Ok(CallToolResult::success(vec![Content::text(format!(
                    "Now operating on Studio instance: {display}"
                ))]))
            }
            0 => {
                let available: Vec<&InstanceSummary> = connected.iter().collect();
                Ok(CallToolResult::error(vec![Content::text(format!(
                    "No connected Studio instance matches {query:?}. Connected instances:\n{}",
                    if available.is_empty() {
                        "(none)".to_string()
                    } else {
                        describe_all(&available)
                    }
                ))]))
            }
            _ => Ok(CallToolResult::error(vec![Content::text(format!(
                "{query:?} matches more than one Studio instance:\n{}\nBe more specific (use the placeId or full id).",
                describe_all(&matches)
            ))])),
        }
    }

    // Picks the DataModel that matches the current session: the client during
    // play mode, `run_server_role` in run mode, edit otherwise. Asks the edit
    // plugin for the mode so it also works from proxying instances, which have
    // no poll-freshness knowledge of their own.
    #[tool(
        description = "Inspect or restore the Roblox Studio window at the OS level. \
        Studio pauses rendering while its window is minimized or fully covered, which silently breaks input and screenshots — tools auto-restore the window and retry once when that happens, \
        but action=status shows the window state (title, minimized, foreground) and action=restore forces the window back to the foreground explicitly."
    )]
    async fn studio_window(
        &self,
        Parameters(args): Parameters<StudioWindow>,
    ) -> Result<CallToolResult, ErrorData> {
        let hint = match args.title.clone() {
            Some(title) => Some(title),
            None => self.window_hint().await,
        };
        let result = tokio::task::spawn_blocking(move || match args.action.as_str() {
            "status" => crate::os_window::studio_windows().map(|windows| {
                serde_json::json!({ "windows": windows }).to_string()
            }),
            "restore" | "focus" => crate::os_window::restore_studio_window(hint.as_deref())
                .map(|title| {
                    serde_json::json!({ "restored": title, "note": "Rendering resumes within a second once the window is visible." }).to_string()
                }),
            other => Err(format!(
                "Invalid action '{other}': must be status or restore"
            )),
        })
        .await
        .map_err(|e| format!("Window control task failed: {e}"))
        .and_then(|inner| inner);
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err)])),
        }
    }

    // The window-title hint for the current selection: the place-name part of
    // the instance id ("placeId|name").
    async fn window_hint(&self) -> Option<String> {
        let instance = self.resolve_instance().await.ok().flatten()?;
        let name = instance.split('|').nth(1)?;
        if name.is_empty() {
            None
        } else {
            Some(name.to_string())
        }
    }

    async fn play_aware_role(
        &self,
        run_server_role: TargetRole,
        instance: Option<String>,
    ) -> Result<TargetRole, String> {
        let mode = self
            .execute_on_instance(
                ToolArgumentValues::GetStudioMode(GetStudioMode {}),
                TargetRole::Edit,
                instance,
            )
            .await?;
        Ok(match mode.trim() {
            "start_play" => TargetRole::Client,
            "run_server" => run_server_role,
            _ => TargetRole::Edit,
        })
    }

    async fn generic_tool_run(
        &self,
        args: ToolArgumentValues,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run_on(args, TargetRole::Edit).await
    }

    async fn generic_tool_run_on(
        &self,
        args: ToolArgumentValues,
        target: TargetRole,
    ) -> Result<CallToolResult, ErrorData> {
        match self.execute_on(args, target).await {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err)])),
        }
    }

    // Decides which Studio window to address: the explicitly selected one if
    // it is still connected, otherwise the single connected one. Returns None
    // on a proxying server with no selection — the port owner resolves then.
    async fn resolve_instance(&self) -> Result<Option<String>, String> {
        let selected = self.selected_instance.lock().await.clone();
        let state = self.state.lock().await;
        // A secondary server (proxying through the port owner) never sees
        // polls, so it cannot validate anything locally.
        if state.instances.is_empty() {
            return Ok(selected);
        }
        match selected {
            Some(selected) => {
                if state.any_role_fresh(&selected) {
                    Ok(Some(selected))
                } else {
                    Err(format!(
                        "The selected Studio instance {} is no longer connected. \
                         Call list_studio_instances to see what is available and \
                         select_studio_instance to switch.",
                        instance_display(&selected)
                    ))
                }
            }
            None => state.resolve_auto_instance().map(Some),
        }
    }

    // Queues a command for one role of one Studio window and waits for its
    // response. The building block for both plain tools and multi-step
    // orchestrations (e.g. take_screenshot capturing on one DataModel and
    // reading pixels on another).
    async fn execute_on(
        &self,
        args: ToolArgumentValues,
        target: TargetRole,
    ) -> Result<String, String> {
        let instance = self.resolve_instance().await?;
        self.execute_on_instance(args, target, instance).await
    }

    async fn execute_on_instance(
        &self,
        args: ToolArgumentValues,
        target: TargetRole,
        instance: Option<String>,
    ) -> Result<String, String> {
        let retry_args = args.clone();
        let result = self
            .execute_on_instance_once(args, target, instance.clone())
            .await;
        // The plugin refuses input/captures while Studio is not rendering
        // (window minimized or fully covered). That is fixable from out here:
        // restore the window at the OS level and retry once.
        let Err(err) = &result else { return result };
        if !err.contains("Studio is not rendering") {
            return result;
        }
        let hint = instance
            .as_deref()
            .and_then(|instance| instance.split('|').nth(1))
            .map(str::to_string);
        let restored = tokio::task::spawn_blocking(move || {
            crate::os_window::restore_studio_window(hint.as_deref())
        })
        .await
        .map_err(|e| e.to_string())
        .and_then(|inner| inner);
        match restored {
            Ok(title) => {
                tracing::info!(
                    "Restored Studio window '{title}' after a not-rendering error; retrying"
                );
                // Give the engine a moment to resume rendering frames.
                tokio::time::sleep(Duration::from_millis(1500)).await;
                self.execute_on_instance_once(retry_args, target, instance)
                    .await
                    .map_err(|e| {
                        format!(
                            "{e} (the Studio window '{title}' was restored automatically \
                             and the command retried once)"
                        )
                    })
            }
            Err(restore_err) => Err(format!(
                "{err} Automatic window restore did not work: {restore_err}"
            )),
        }
    }

    async fn execute_on_instance_once(
        &self,
        args: ToolArgumentValues,
        target: TargetRole,
        instance: Option<String>,
    ) -> Result<String, String> {
        // On a proxying server `instance` may be None; the port owner enforces
        // resolution and freshness in proxy_handler instead.
        if target != TargetRole::Edit {
            if let Some(ref instance) = instance {
                let knows_polls = { !self.state.lock().await.instances.is_empty() };
                if knows_polls {
                    wait_for_role(&self.state, instance, target).await?;
                }
            }
        }
        let run_timeout = execution_timeout(&args);
        let (command, id) = ToolArguments::new(args, target, instance);
        tracing::debug!("Running command: {:?}", command);
        let (tx, mut rx) = mpsc::unbounded_channel::<Result<String>>();
        let trigger = {
            let mut state = self.state.lock().await;
            state.process_queue.push_back(QueuedTask {
                command: command.clone(),
                attempts: 0,
            });
            state.output_map.insert(id, tx);
            state.trigger.clone()
        };
        trigger
            .send(())
            .map_err(|e| format!("Unable to trigger send {e}"))?;
        let result = match tokio::time::timeout(run_timeout, rx.recv()).await {
            Ok(result) => result.ok_or("Couldn't receive response".to_string())?,
            Err(_) => {
                let plugin_status = {
                    let mut state = self.state.lock().await;
                    state
                        .process_queue
                        .retain(|task| task.command.id != Some(id));
                    state.inflight.remove(&id);
                    state.output_map.remove(&id);
                    state.poll_status(command.instance.as_deref(), target)
                };
                return Err(format!(
                    "Timed out after {}s waiting for Roblox Studio ({plugin_status}). \
                     Studio may be busy (publishing or loading) or the MCP plugin may be \
                     disconnected. Make sure Studio is open with the MCP plugin enabled, \
                     then try again.",
                    run_timeout.as_secs()
                ));
            }
        };
        {
            let mut state = self.state.lock().await;
            state.output_map.remove_entry(&id);
        }
        tracing::debug!("Sending to MCP: {result:?}");
        result.map_err(|err| err.to_string())
    }
}

// Waits for the target DataModel of one Studio window to be polling. Play-mode
// DataModels take a few seconds to load plugins after start_stop_play returns,
// so a brief wait avoids spurious failures right after play start.
async fn wait_for_role(
    state: &PackedState,
    instance: &str,
    target: TargetRole,
) -> Result<(), String> {
    let deadline = Instant::now() + ROLE_WAIT_TIMEOUT;
    loop {
        if state.lock().await.role_fresh(instance, target) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "{} (Studio instance: {})",
                target.describe_missing(),
                instance_display(instance)
            ));
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

// Returns unacknowledged commands to the queue so a delivery that died with
// its connection (e.g. Studio aborted the long poll while publishing) is
// retried instead of hanging the tool call forever.
fn requeue_expired_inflight(state: &mut AppState) {
    let now = Instant::now();
    let expired: Vec<Uuid> = state
        .inflight
        .iter()
        .filter(|(_, inflight)| now.duration_since(inflight.delivered_at) >= ACK_TIMEOUT)
        .map(|(id, _)| *id)
        .collect();
    for id in expired {
        let Some(inflight) = state.inflight.remove(&id) else {
            continue;
        };
        let task = inflight.task;
        if task.attempts >= MAX_DELIVERY_ATTEMPTS {
            tracing::warn!(
                "Giving up on command {id} after {} delivery attempts",
                task.attempts
            );
            if let Some(tx) = state.output_map.remove(&id) {
                let _ = tx.send(Err(Report::from(eyre!(
                    "Failed to deliver the command to Roblox Studio after {} attempts. \
                     Studio may be frozen or the MCP plugin disconnected.",
                    task.attempts
                ))));
            }
        } else {
            tracing::debug!(
                "Studio never acknowledged command {id} (attempt {}); requeueing",
                task.attempts
            );
            state.process_queue.push_front(task);
        }
    }
}

fn legacy_role() -> TargetRole {
    TargetRole::Legacy
}

#[derive(Deserialize, Debug)]
struct RequestQuery {
    #[serde(default = "legacy_role")]
    role: TargetRole,
    // "placeId|placeName" identifying the Studio window. Older plugins omit it.
    instance: Option<String>,
}

async fn request_handler(
    State(state): State<PackedState>,
    Query(query): Query<RequestQuery>,
) -> Result<impl IntoResponse> {
    let role = query.role;
    let instance = query.instance.unwrap_or_else(|| "default".to_string());
    tracing::debug!("Long poll from {role:?} of {instance}");
    let deadline = Instant::now() + LONG_POLL_DURATION;
    let mut waiter = {
        let mut state = state.lock().await;
        state.note_poll(&instance, role);
        state.waiter.clone()
    };
    loop {
        {
            let mut state = state.lock().await;
            state.note_poll(&instance, role);
            requeue_expired_inflight(&mut state);
            // Deliver the oldest command addressed to this role of this Studio
            // window; everything else stays queued for its own poller.
            let next = state.process_queue.iter().position(|task| {
                task.command.target == role && task.command.instance.as_deref() == Some(&instance)
            });
            if let Some(pos) = next {
                let mut task = state
                    .process_queue
                    .remove(pos)
                    .ok_or_eyre("Queued task disappeared")?;
                task.attempts += 1;
                let command = task.command.clone();
                // Track the command as in flight before any await: if this
                // response never reaches the plugin, the ack watchdog above
                // requeues it instead of losing it.
                if let Some(id) = task.command.id {
                    state.inflight.insert(
                        id,
                        InflightTask {
                            task,
                            delivered_at: Instant::now(),
                        },
                    );
                }
                return Ok(Json(command).into_response());
            }
        }
        let now = Instant::now();
        if now >= deadline {
            return Ok((StatusCode::LOCKED, String::new()).into_response());
        }
        // Wake periodically even without new tasks so the inflight sweep runs.
        let wait = INFLIGHT_SWEEP_INTERVAL.min(deadline - now);
        let _ = tokio::time::timeout(wait, waiter.changed()).await;
    }
}

// Read-only view of connected Studio windows, served over HTTP so that
// secondary (proxying) MCP server processes can query the port owner's data.
async fn instances_handler(State(state): State<PackedState>) -> Json<Vec<InstanceSummary>> {
    let state = state.lock().await;
    let mut list: Vec<InstanceSummary> = state
        .instances
        .iter()
        .map(|(id, inst)| {
            let (place_id, name) = id.split_once('|').unwrap_or(("", id.as_str()));
            let mut connected_roles: Vec<String> = inst
                .last_poll
                .iter()
                .filter(|(_, at)| at.elapsed() < ROLE_FRESHNESS)
                .map(|(role, _)| format!("{role:?}").to_lowercase())
                .collect();
            connected_roles.sort();
            InstanceSummary {
                id: id.clone(),
                name: name.to_string(),
                place_id: place_id.to_string(),
                connected_roles,
                seconds_since_poll: inst.seconds_since_poll().unwrap_or(u64::MAX),
            }
        })
        .collect();
    list.sort_by(|a, b| a.id.cmp(&b.id));
    Json(list)
}

async fn ack_handler(
    State(state): State<PackedState>,
    Json(payload): Json<AckRequest>,
) -> impl IntoResponse {
    tracing::debug!("Studio acknowledged {}", payload.id);
    let mut state = state.lock().await;
    if state.inflight.remove(&payload.id).is_none() {
        // The watchdog may have requeued it before this ack arrived; the
        // plugin has the command, so drop the queued duplicate.
        state
            .process_queue
            .retain(|task| task.command.id != Some(payload.id));
    }
    StatusCode::OK
}

async fn response_handler(
    State(state): State<PackedState>,
    Json(payload): Json<RunCommandResponse>,
) -> Result<impl IntoResponse> {
    tracing::debug!("Received reply from studio {payload:?}");
    let mut state = state.lock().await;
    // A response is also an implicit ack: stop any pending redelivery.
    state.inflight.remove(&payload.id);
    state
        .process_queue
        .retain(|task| task.command.id != Some(payload.id));
    let Some(tx) = state.output_map.remove(&payload.id) else {
        // The caller most likely timed out and cleaned up; accept the response
        // anyway so the plugin does not keep retrying it.
        tracing::debug!("Received response for unknown id {}", payload.id);
        return Ok(StatusCode::OK);
    };
    let result: Result<String, Report> = if payload.success {
        Ok(payload.response)
    } else {
        Err(Report::from(eyre!(payload.response)))
    };
    if tx.send(result).is_err() {
        tracing::debug!("Output receiver for {} is gone", payload.id);
    }
    Ok(StatusCode::OK)
}

async fn proxy_handler(
    State(state): State<PackedState>,
    Json(mut command): Json<ToolArguments>,
) -> Result<impl IntoResponse> {
    let id = command.id.ok_or_eyre("Got proxy command with no id")?;
    tracing::debug!("Received request to proxy {command:?}");
    // Secondary servers forward commands without poll knowledge; resolve the
    // Studio window and enforce role freshness here so misaddressed commands
    // fail fast instead of sitting in the queue until their timeout.
    let instance = match command.instance.clone() {
        Some(instance) => instance,
        None => match state.lock().await.resolve_auto_instance() {
            Ok(instance) => instance,
            Err(message) => {
                return Ok(Json(RunCommandResponse {
                    success: false,
                    response: message,
                    id,
                }));
            }
        },
    };
    command.instance = Some(instance.clone());
    if command.target != TargetRole::Edit {
        if let Err(message) = wait_for_role(&state, &instance, command.target).await {
            return Ok(Json(RunCommandResponse {
                success: false,
                response: message,
                id,
            }));
        }
    }
    let run_timeout = execution_timeout(&command.args);
    let (tx, mut rx) = mpsc::unbounded_channel();
    let trigger = {
        let mut state = state.lock().await;
        state.process_queue.push_back(QueuedTask {
            command,
            attempts: 0,
        });
        state.output_map.insert(id, tx);
        state.trigger.clone()
    };
    // Wake the pending long poll. Without this, proxied commands sat in the
    // queue until the current long poll expired (up to 15 seconds).
    let _ = trigger.send(());
    let result = match tokio::time::timeout(run_timeout, rx.recv()).await {
        Ok(result) => result.ok_or_eyre("Couldn't receive response")?,
        Err(_) => Err(Report::from(eyre!(
            "Timed out after {}s waiting for Roblox Studio",
            run_timeout.as_secs()
        ))),
    };
    {
        let mut state = state.lock().await;
        state
            .process_queue
            .retain(|task| task.command.id != Some(id));
        state.inflight.remove(&id);
        state.output_map.remove_entry(&id);
    }
    let (success, response) = match result {
        Ok(s) => (true, s),
        Err(e) => (false, e.to_string()),
    };
    tracing::debug!("Sending back to dud: success={success}, response={response:?}");
    Ok(Json(RunCommandResponse {
        success,
        response,
        id,
    }))
}

enum DudExit {
    Shutdown,
    PrimaryGone,
}

async fn deliver_result(state: &PackedState, id: Option<Uuid>, result: Result<String>) {
    let Some(id) = id else { return };
    let tx = { state.lock().await.output_map.remove(&id) };
    match tx {
        Some(tx) => {
            if tx.send(result).is_err() {
                tracing::debug!("Output receiver for {id} is gone (caller timed out)");
            }
        }
        None => tracing::debug!("No output channel for {id} (caller timed out)"),
    }
}

async fn dud_proxy_loop(state: PackedState, mut shutdown: watch::Receiver<bool>) -> DudExit {
    let client = match reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(3))
        .build()
    {
        Ok(client) => client,
        Err(err) => {
            tracing::error!("Failed to build proxy HTTP client: {err}");
            return DudExit::Shutdown;
        }
    };

    let mut waiter = { state.lock().await.waiter.clone() };
    loop {
        if *shutdown.borrow() {
            return DudExit::Shutdown;
        }
        let entry = { state.lock().await.process_queue.pop_front() };
        let Some(entry) = entry else {
            tokio::select! {
                _ = waiter.changed() => {}
                _ = shutdown.changed() => {}
            }
            continue;
        };
        let request_timeout = execution_timeout(&entry.command.args) + Duration::from_secs(30);
        let res = client
            .post(format!("http://127.0.0.1:{STUDIO_PLUGIN_PORT}/proxy"))
            .timeout(request_timeout)
            .json(&entry.command)
            .send()
            .await;
        match res {
            Ok(res) => {
                let result = match res.json::<RunCommandResponse>().await {
                    Ok(reply) if reply.success => Ok(reply.response),
                    Ok(reply) => Err(Report::from(eyre!(reply.response))),
                    Err(err) => Err(err.into()),
                };
                deliver_result(&state, entry.command.id, result).await;
            }
            Err(err) if err.is_connect() => {
                tracing::warn!("Primary MCP instance is unreachable: {err}");
                // Put the command back so it survives the takeover of the port.
                state.lock().await.process_queue.push_front(entry);
                return DudExit::PrimaryGone;
            }
            Err(err) => {
                tracing::error!("Failed to proxy: {err:?}");
                deliver_result(
                    &state,
                    entry.command.id,
                    Err(Report::from(eyre!(
                        "Failed to forward command to the primary MCP instance: {err}"
                    ))),
                )
                .await;
            }
        }
    }
}

// Serves HTTP for the Studio plugin when the port is free; otherwise proxies
// to the instance that owns the port and takes the port over when that
// instance exits.
pub async fn serve_http(state: PackedState, close_rx: watch::Receiver<bool>) {
    loop {
        if *close_rx.borrow() {
            return;
        }
        match tokio::net::TcpListener::bind((Ipv4Addr::new(127, 0, 0, 1), STUDIO_PLUGIN_PORT)).await
        {
            Ok(listener) => {
                tracing::info!(
                    "This MCP instance is HTTP server listening on {STUDIO_PLUGIN_PORT}"
                );
                let app = Router::new()
                    .route("/request", get(request_handler))
                    .route("/response", post(response_handler))
                    .route("/ack", post(ack_handler))
                    .route("/proxy", post(proxy_handler))
                    .route("/instances", get(instances_handler))
                    // Screenshot responses carry multiple MB of base64 pixel
                    // data; axum's default 2 MB body limit would reject them
                    // with 413 and hang the calling tool until its timeout.
                    .layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024))
                    .with_state(Arc::clone(&state));
                let mut shutdown = close_rx.clone();
                let result = axum::serve(listener, app)
                    .with_graceful_shutdown(async move {
                        let _ = shutdown.wait_for(|closed| *closed).await;
                    })
                    .await;
                if let Err(err) = result {
                    tracing::error!("HTTP server failed: {err}; retrying");
                    tokio::time::sleep(PORT_REBIND_DELAY).await;
                    continue;
                }
                return;
            }
            Err(_) => {
                tracing::info!("This MCP instance will use proxy since port is busy");
                match dud_proxy_loop(Arc::clone(&state), close_rx.clone()).await {
                    DudExit::Shutdown => return,
                    DudExit::PrimaryGone => {
                        tracing::info!("Attempting to take over port {STUDIO_PLUGIN_PORT}");
                        tokio::time::sleep(PORT_REBIND_DELAY).await;
                    }
                }
            }
        }
    }
}
