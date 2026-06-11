# Nâng cấp Roblox Studio MCP: Khả năng Play-Test End-to-End

## Context (Bối cảnh)

MCP server hiện tại (Rust + Studio plugin Luau) chỉ chạy code và điều khiển play mode — không "nhìn" và không "chơi" được game. Mục tiêu: AI agent test một tính năng end-to-end như người chơi thật — **chụp ảnh màn hình trong game** (cả viewport lẫn từng ScreenGui riêng — `takeImage(ScreenUI)`), **đọc cây UI**, **click chuột / gõ phím / nhập text qua pipeline input thật**, **điều khiển nhân vật**, **chạy code theo context** (edit/server/client), và **wait-for-condition** để test ổn định.

Phạm vi đã chốt với user: **Core E2E trước** (multiplayer nhiều client = phase 2), **có OS-fallback chụp ảnh** (Windows), verify bằng **test place tự tạo**.

## Phát hiện nghiên cứu then chốt (đã verify)

1. **Chụp ảnh trong game**: `CaptureService:CaptureScreenshot()` (chạy trên DM đang render) → temp `rbxtemp://` contentId → **edit DM** (plugin context có đặc quyền) gọi `AssetService:CreateEditableImageAsync(Content.fromUri(id))` → `ReadPixelsBuffer` theo tile 1024×1024 → base64 → Rust encode PNG. Kỹ thuật này đã được chứng minh hoạt động bởi dự án cộng đồng Chrrxs/robloxstudio-mcp.
2. **Giả lập input**: `UserInputService:CreateVirtualInput()` — gọi được từ plugin context (KHÔNG dùng `VirtualInputManager` — bị khóa RobloxScriptSecurity; `VirtualUser` đã mục nát). Trả object có `SendKey(isDown, keyCode)`, `SendMouseButton(pos, inputType, isDown)`, `SendTextInput(text)` — đẩy vào pipeline input THẬT (WASD đi được nhân vật, click kích hoạt GuiButton). Phải chạy trên **client DM** khi play. Input bị drop âm thầm khi cửa sổ không render (minimize) → cần check RenderStepped freshness.
3. **Peer routing**: HttpService dùng được từ plugin context ở MỌI DataModel → mỗi plugin instance (edit/server/client) tự poll HTTP server với role riêng.
4. **rmcp 0.14 có `Content::image(data_b64, mime_type)`** — verified trong vendored source (`rmcp-0.14.0/src/model/content.rs:165`). Crates `image 0.25`, `xcap 0.9`, `base64 0.22` khả dụng.
5. **Bug đã biết**: CaptureScreenshot callback đôi khi không fire → race timeout 5s + fallback OS capture.

## Kiến trúc hiện tại (điểm tích hợp)

- `src/rbx_studio_server.rs` — toàn bộ Rust: tool structs + `#[tool]` methods (dòng 135–267), `ToolArguments { args, id }`, 1 `process_queue` toàn cục, `output_map` theo Uuid, axum routes `/request` (long-poll GET), `/response`, `/ack`, `/proxy` (dud-proxy mode — field mới trên `ToolArguments` tự serialize xuyên qua).
- `plugin/src/Main.server.luau:37` — `if RunService:IsRunning() then return end` → play DM hiện KHÔNG kết nối. `GameStopUtil.monitorForStopPlay` spawn cho Server DM TRƯỚC dòng này (phải giữ nguyên thứ tự).
- `plugin/src/Utils/ToolDispatcher.luau` — registry tool Luau; `plugin/src/Types.luau` — arg types.
- `build.rs` rojo-build cả thư mục `plugin/` (`rerun-if-changed=plugin`) → file `.luau` mới tự được đóng gói, không cần sửa build.rs/`default.project.json`.
- Timeout có 3 bản mirror phải sửa đồng bộ: Rust `execution_timeout()`, Luau `executionTimeout()` (Main.server.luau), dud-proxy (tự kế thừa từ `execution_timeout`).

## Spikes (chạy TRƯỚC qua `run_code` hiện có, không sửa code)

- **S1 — Giới hạn body HTTP** (gating M2): từ run_code POST payload giả vào `/response` với size 0.5/1/1.9/3/8 MB. Lỗi pcall = trần Luau HttpService; HTTP 413 = trần axum 2MB. Quyết định: single-POST (nâng limit) hay chunked `/upload`.
- **S2 — Đường capture** (edit DM): CaptureScreenshot → CreateEditableImageAsync → ReadPixelsBuffer 64×64. Trả lời: callback có fire không, **có nhận content >1024×1024 không** (nếu không → downscale bằng `DrawImageTransformed` phía plugin), kích thước capture vs `ViewportSize` vs `GetGuiInset`.
- **S3 — CreateVirtualInput tồn tại?** — go/no-go cho M4. Gọi sai args để đọc error message lộ signature.
- **S4 — Tốc độ encoder Base64 Luau** trên buffer 4MB (phải < 1s).
- **S5 (sau M1) — temp contentId xuyên DM**: capture trên client, đọc trên edit khi đang play. Nếu fail → capture+read đều trên client DM.
- **S6 (sau M1) — Calibrate tọa độ click**: TextButton ở vị trí biết trước, thử `SendMouseButton` có/không cộng `GetGuiInset()`, xem biến thể nào fire `.Activated`. Hardcode convention thắng cuộc vào `UiQuery.luau`. Thử SendKey W 0.5s đo delta vị trí nhân vật.

## Milestones

### M1 — Peer routing (nền tảng, mọi thứ phụ thuộc)

**Rust (`src/rbx_studio_server.rs`):**
- `enum TargetRole { #[default] Edit, Server, Client }` (serde lowercase); thêm `#[serde(default)] target: TargetRole` vào `ToolArguments` (backward-compatible, xuyên `/proxy` tự động).
- GIỮ 1 queue duy nhất; `request_handler` nhận `Query<{role}>`, pop **task đầu tiên match role** (`iter().position()` + `remove(pos)`) — không đổi inflight/ack/requeue/dud-proxy.
- `last_poll: HashMap<TargetRole, Instant>`; **fast-fail** trong `generic_tool_run` nếu role đích không poll trong 3s ("No play-mode client is connected; start play mode first").
- Refactor: `execute_on(args, target) -> Result<String, String>` (dùng cho orchestration nhiều bước) + `role_connected()`.
- Thêm `context: Option<String>` vào `RunCode`, `GetConsoleOutput`.

**Plugin (`plugin/src/Main.server.luau`):**
- Bỏ early-return dòng 37; mọi DM connect với role qua `?role=<edit|server|client>` (chỉ cần đổi receive endpoint string — không sửa MockWebSocketService).
- Edit-only: toolbar, `TryBeginRecording`, timeout-path `GameStopUtil.stopPlay` (guard tường minh `datamodelType == "Edit"`). Mỗi DM tự `ConsoleOutput.startListener()`.

**Test M1:** regression 6 tool cũ; `run_code(context="client", "print(game.Players.LocalPlayer)")` khi đang play; rồi chạy S5+S6.

### M2 — Pipeline chụp ảnh

**Plugin mới:** `Utils/Base64.luau` (buffer+bit32 encoder); `Tools/TakeScreenshotCapture.luau` (args `{ui_path?, isolate?}`: resolve UI, nếu `isolate` thì tắt các ScreenGui anh em rồi restore trong finally; CaptureScreenshot với race timeout 5s; trả `{contentId, rect?, viewport}`); `Tools/TakeScreenshotRead.luau` (args `{content_id, rect?, max_dimension}`: CreateEditableImageAsync → downscale `DrawImageTransformed` nếu cần → ReadPixelsBuffer (tile 1024 nếu S2 yêu cầu) → trả `{width, height, pixels: b64}`). Đăng ký vào ToolDispatcher + Types.

**Rust:** deps `image`, `base64`. Variant nội bộ `ScreenshotCapture`/`ScreenshotRead` trong `ToolArgumentValues` (không expose `#[tool]`). Tool public:
```rust
struct TakeScreenshot { ui_path: Option<String>, isolate: Option<bool>, max_dimension: Option<u32> /*1280*/, format: Option<String> /*png|jpeg*/ }
```
Orchestration: GetStudioMode → chọn role capture (`start_play`→Client, `run_server`→Server, `stop`→Edit) → đợi ≤10s poll-freshness (tránh race lúc mới start play) → Capture trên role đó → Read trên Edit (fallback: read tại chỗ nếu S5 fail) → decode RGBA → resize backstop → encode PNG/JPEG → `vec![Content::image(b64, mime), Content::text(metadata_json)]`.
**Bắt buộc:** nâng `DefaultBodyLimit::max(64MB)` trên router (413 hiện làm caller treo 300s vì plugin coi 4xx là non-retryable). Nếu S1 lộ trần Luau < ~6MB → thêm endpoint chunked `POST /upload`.

### M3 — OS-fallback (xcap)

`src/os_capture.rs`: `capture_studio_window() -> Result<RgbaImage>` — `xcap::Window::all()`, tìm title chứa "Roblox Studio", `capture_image()`, gọi qua `spawn_blocking`. Kích hoạt khi CAPTURE_TIMEOUT / cross-DM fail / role unreachable. Metadata `source: "os_window"` + caveat (có Studio chrome, tọa độ không map pixel UI).

### M4 — UI tree + Input

**Plugin Utils:**
- `Utils/UiQuery.luau`: `resolve(path)` (dot-path, root mặc định PlayerGui/StarterGui, error liệt kê children khi miss), `centerInViewport(gui)` (convention inset từ S6), `pixelRect(gui)` (không gian pixel screenshot, clamp viewport), `serializeTree(root, maxDepth, includeInvisible)` (name/class/path/pos/size/visible/text/image/zindex).
- `Utils/VirtualInput.luau`: lazy `CreateVirtualInput()` (error rõ nếu API thiếu), `assertRendering()` (RenderStepped stale >0.5s → "Studio window is not rendering (minimized?)"), `click(pos, button, action)`, `key(keyCode, isDown)`, `text(s)`.

**Plugin Tools + Rust tools:**
- `get_ui_tree { root?, max_depth /*6*/, include_invisible? }` — Client nếu fresh, không thì Edit.
- `click_ui { path? | x?,y?, button /*left*/, action /*click|down|up*/ }` — Client only; path → centerInViewport; click = down→delay nhỏ→up.
- `send_key { key, action /*tap|press|release*/, duration? }` — validate `Enum.KeyCode[key]`; press/release cho phím giữ (đi bộ liên tục).
- `send_text { text, textbox_path? }` — `TextBox:CaptureFocus()` trước (fallback click-to-focus) rồi `SendTextInput`.
- Mỗi tool fast-fail có message rõ khi gọi sai mode (run_server không có client/PlayerGui).

### M5 — Điều khiển nhân vật + wait_for

- `control_character { action: move_to|walk|jump|stop|get_state, x?,y?,z?, duration? }` — Client only. move_to: `Humanoid:MoveTo` + `MoveToFinished:Wait()` có timeout; walk: `Humanoid:Move(dir)` trong duration (fallback VirtualInput WASD theo S6); get_state: JSON position/health/state/WalkSpeed/seated.
- `wait_for { condition /*Luau code trả truthy*/, timeout /*30*/, poll_interval /*0.5*/, context? }` — loop loadstring trong pcall, trả `{satisfied, elapsed, value, last_error}`.
- **Timeout 3 nơi:** Rust `execution_timeout` thêm arm `WaitFor => timeout + grace`; Luau `executionTimeout` thêm arm `"WaitFor"`; dud-proxy tự kế thừa.

### M6 — Hoàn thiện

- Cập nhật `ServerInfo.instructions` (workflow play-test: start play → wait_for player → screenshot → vòng lặp interact/verify), tool list trong `install.rs` `get_message`, README section mới.
- Rà error message: mọi lỗi cross-DM nêu rõ role thiếu + cách fix.
- `cargo clippy`/`fmt`, `selene`/`stylua` cho plugin (CI checks có sẵn).

## Bảng rủi ro chính

| Rủi ro | Spike | Mitigation |
|---|---|---|
| Trần body Luau/axum → treo 300s | S1 | DefaultBodyLimit 64MB (bắt buộc) + downscale phía plugin; contingency chunked /upload |
| CreateEditableImageAsync từ chối >1024² | S2 | DrawImageTransformed downscale; hoặc xcap thành primary |
| CaptureScreenshot không fire (bug đã biết) | S2 | race 5s → xcap fallback |
| temp contentId không đọc được xuyên DM | S5 | capture+read cùng trên client DM |
| CreateVirtualInput thiếu/đổi tên | S3 | hard blocker M4 — verify trước; gate feature theo availability |
| Lệch tọa độ (AbsolutePosition/inset/pixels) | S6 | calibrate 1 lần, hardcode vào UiQuery |
| Input drop khi minimize | S6 | assertRendering() báo lỗi thay vì false-success |
| Screenshot ngay sau start play (client chưa poll) | — | đợi ≤10s poll-freshness theo mode |

## Thứ tự thực hiện

1. Spikes S1→S4 (qua run_code, không sửa code) → 2. **M1** → 3. S5+S6 → 4. **M2** → **M3** → 5. **M4** → **M5** → **M6**.

Mỗi milestone: `cargo build` (tự rebuild plugin), reinstall plugin, restart Studio, regression 6 tool cũ + tool mới.

## Verification cuối (E2E trên test place tự tạo)

1. Dùng `run_code` dựng test place: ScreenGui có TextButton (click tăng counter trên TextLabel), TextBox, nút mở Frame "Shop", baseplate + spawn.
2. Kịch bản E2E như người chơi thật: `start_stop_play(start_play)` → `wait_for(LocalPlayer.Character)` → `take_screenshot` (toàn màn hình) → `get_ui_tree` → `click_ui(path=nút counter)` → `wait_for(label text đổi)` → `take_screenshot(ui_path=ScreenGui đó)` (kiểm tra crop + isolate) → `send_text` vào TextBox → `click_ui(nút Shop)` → screenshot xác nhận Frame mở → `control_character(move_to)` + `jump` → screenshot → `start_stop_play(stop)`.
3. Kiểm tra ảnh trả về xem được trong MCP client (Content::image), metadata đúng, mọi bước không treo watchdog.

## File then chốt

- `src/rbx_studio_server.rs` — TargetRole, role-filtered pop, toàn bộ tool struct/method mới, orchestration take_screenshot, body limit
- `src/os_capture.rs` (mới) — xcap fallback
- `plugin/src/Main.server.luau` — multi-DM connect, role polling, edit-only guards
- `plugin/src/Utils/` — `Base64.luau`, `UiQuery.luau`, `VirtualInput.luau` (mới), `ToolDispatcher.luau` (đăng ký)
- `plugin/src/Tools/` — `TakeScreenshotCapture/Read`, `GetUiTree`, `ClickUi`, `SendKey`, `SendText`, `ControlCharacter`, `WaitFor` (mới)
- `plugin/src/Types.luau`, `Cargo.toml` (image, base64, xcap), `src/install.rs`, README
