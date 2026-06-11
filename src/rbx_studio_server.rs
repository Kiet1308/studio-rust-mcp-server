use crate::error::{Report, Result};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{extract::State, Json, Router};
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

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct ToolArguments {
    args: ToolArgumentValues,
    id: Option<Uuid>,
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

pub struct AppState {
    process_queue: VecDeque<QueuedTask>,
    // Commands handed to a long poll but not yet acknowledged by the plugin.
    inflight: HashMap<Uuid, InflightTask>,
    output_map: HashMap<Uuid, mpsc::UnboundedSender<Result<String>>>,
    last_poll: Option<Instant>,
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
            last_poll: None,
            waiter,
            trigger,
        }
    }
}

impl ToolArguments {
    fn new(args: ToolArgumentValues) -> (Self, Uuid) {
        Self { args, id: None }.with_id()
    }
    fn with_id(self) -> (Self, Uuid) {
        let id = Uuid::new_v4();
        (
            Self {
                args: self.args,
                id: Some(id),
            },
            id,
        )
    }
}
#[derive(Clone)]
pub struct RBXStudioServer {
    state: PackedState,
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
                "You must aware of current studio mode before using any tools, infer the mode from conversation context or get_studio_mode.
User run_code to query data from Roblox Studio place or to change it
After calling run_script_in_play_mode, the datamodel status will be reset to stop mode.
Prefer using start_stop_play tool instead run_script_in_play_mode, Only used run_script_in_play_mode to run one time unit test code on server datamodel.
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
}
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct InsertModel {
    #[schemars(description = "Query to search for the model")]
    query: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct GetConsoleOutput {}

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
enum ToolArgumentValues {
    RunCode(RunCode),
    InsertModel(InsertModel),
    GetConsoleOutput(GetConsoleOutput),
    StartStopPlay(StartStopPlay),
    RunScriptInPlayMode(RunScriptInPlayMode),
    GetStudioMode(GetStudioMode),
}

// How long the MCP side waits for Studio before giving up on a command.
// Without a bound here, a command lost to a dead connection would hang the
// tool call forever.
fn execution_timeout(args: &ToolArgumentValues) -> Duration {
    match args {
        ToolArgumentValues::RunScriptInPlayMode(args) => {
            Duration::from_secs(u64::from(args.timeout.unwrap_or(100))) + PLAY_MODE_TIMEOUT_GRACE
        }
        _ => DEFAULT_TOOL_TIMEOUT,
    }
}

#[tool_router]
impl RBXStudioServer {
    pub fn new(state: PackedState) -> Self {
        Self {
            state,
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        description = "Runs a command in Roblox Studio and returns the printed output. Can be used to both make changes and retrieve information"
    )]
    async fn run_code(
        &self,
        Parameters(args): Parameters<RunCode>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::RunCode(args))
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

    #[tool(description = "Get the console output from Roblox Studio.")]
    async fn get_console_output(
        &self,
        Parameters(args): Parameters<GetConsoleOutput>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::GetConsoleOutput(args))
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

    async fn generic_tool_run(
        &self,
        args: ToolArgumentValues,
    ) -> Result<CallToolResult, ErrorData> {
        let run_timeout = execution_timeout(&args);
        let (command, id) = ToolArguments::new(args);
        tracing::debug!("Running command: {:?}", command);
        let (tx, mut rx) = mpsc::unbounded_channel::<Result<String>>();
        let trigger = {
            let mut state = self.state.lock().await;
            state.process_queue.push_back(QueuedTask {
                command,
                attempts: 0,
            });
            state.output_map.insert(id, tx);
            state.trigger.clone()
        };
        trigger
            .send(())
            .map_err(|e| ErrorData::internal_error(format!("Unable to trigger send {e}"), None))?;
        let result = match tokio::time::timeout(run_timeout, rx.recv()).await {
            Ok(result) => {
                result.ok_or(ErrorData::internal_error("Couldn't receive response", None))?
            }
            Err(_) => {
                let last_poll = {
                    let mut state = self.state.lock().await;
                    state
                        .process_queue
                        .retain(|task| task.command.id != Some(id));
                    state.inflight.remove(&id);
                    state.output_map.remove(&id);
                    state.last_poll
                };
                let plugin_status = match last_poll {
                    Some(at) => format!(
                        "last poll from the Studio plugin was {}s ago",
                        at.elapsed().as_secs()
                    ),
                    None => "the Studio plugin has not connected yet".to_string(),
                };
                return Ok(CallToolResult::error(vec![Content::text(format!(
                    "Timed out after {}s waiting for Roblox Studio ({plugin_status}). \
                     Studio may be busy (publishing or loading) or the MCP plugin may be \
                     disconnected. Make sure Studio is open with the MCP plugin enabled, \
                     then try again.",
                    run_timeout.as_secs()
                ))]));
            }
        };
        {
            let mut state = self.state.lock().await;
            state.output_map.remove_entry(&id);
        }
        tracing::debug!("Sending to MCP: {result:?}");
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err.to_string())])),
        }
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

async fn request_handler(State(state): State<PackedState>) -> Result<impl IntoResponse> {
    let deadline = Instant::now() + LONG_POLL_DURATION;
    let mut waiter = {
        let mut state = state.lock().await;
        state.last_poll = Some(Instant::now());
        state.waiter.clone()
    };
    loop {
        {
            let mut state = state.lock().await;
            state.last_poll = Some(Instant::now());
            requeue_expired_inflight(&mut state);
            if let Some(mut task) = state.process_queue.pop_front() {
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
    Json(command): Json<ToolArguments>,
) -> Result<impl IntoResponse> {
    let id = command.id.ok_or_eyre("Got proxy command with no id")?;
    tracing::debug!("Received request to proxy {command:?}");
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
        match tokio::net::TcpListener::bind((Ipv4Addr::new(127, 0, 0, 1), STUDIO_PLUGIN_PORT))
            .await
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
