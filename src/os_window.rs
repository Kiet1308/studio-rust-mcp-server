//! OS-level control of the Roblox Studio window.
//!
//! Studio pauses rendering while its window is minimized or fully covered,
//! which makes the engine silently drop virtual input and breaks screenshots.
//! Restoring the window from inside the engine is impossible, so the server
//! does it at the OS level: the studio_window tool exposes it explicitly, and
//! command execution retries once after an automatic restore when the plugin
//! reports "Studio is not rendering".
//!
//! Plain SW_SHOWNOACTIVATE / SetWindowPos without activation is NOT enough —
//! a fully covered window still does not render — so restore really brings
//! the window to the foreground (verified empirically on Windows 11).

use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct StudioWindowInfo {
    pub title: String,
    pub minimized: bool,
    pub foreground: bool,
}

#[cfg(target_os = "windows")]
mod imp {
    use super::StudioWindowInfo;
    use windows_sys::Win32::Foundation::{HWND, LPARAM};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{keybd_event, KEYEVENTF_KEYUP, VK_MENU};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW, IsIconic,
        IsWindowVisible, SetForegroundWindow, ShowWindow, SW_RESTORE,
    };

    struct EnumState {
        windows: Vec<(isize, String)>,
    }

    unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> i32 {
        let state = &mut *(lparam as *mut EnumState);
        if IsWindowVisible(hwnd) == 0 {
            return 1;
        }
        let len = GetWindowTextLengthW(hwnd);
        if len <= 0 {
            return 1;
        }
        let mut buf = vec![0u16; (len + 1) as usize];
        let read = GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32);
        if read > 0 {
            let title = String::from_utf16_lossy(&buf[..read as usize]);
            if title.contains("Roblox Studio") {
                state.windows.push((hwnd as isize, title));
            }
        }
        1
    }

    fn list_raw() -> Vec<(isize, String)> {
        let mut state = EnumState {
            windows: Vec::new(),
        };
        unsafe {
            EnumWindows(Some(enum_proc), &mut state as *mut EnumState as LPARAM);
        }
        state.windows
    }

    pub fn studio_windows() -> Result<Vec<StudioWindowInfo>, String> {
        let foreground = unsafe { GetForegroundWindow() } as isize;
        Ok(list_raw()
            .into_iter()
            .map(|(hwnd, title)| StudioWindowInfo {
                title,
                minimized: unsafe { IsIconic(hwnd as HWND) } != 0,
                foreground: hwnd == foreground,
            })
            .collect())
    }

    // Picks the window a hint refers to. Hints are instance names, which for
    // file-based places carry an extension the window title does not.
    fn pick(windows: &[(isize, String)], hint: Option<&str>) -> Result<(isize, String), String> {
        if windows.is_empty() {
            return Err("No Roblox Studio window found (is Studio running?)".to_string());
        }
        if let Some(hint) = hint {
            let hint = hint.to_lowercase();
            let stem = hint
                .trim_end_matches(".rbxlx")
                .trim_end_matches(".rbxl")
                .to_string();
            if let Some(found) = windows.iter().find(|(_, title)| {
                let title = title.to_lowercase();
                title.contains(&hint) || (!stem.is_empty() && title.contains(&stem))
            }) {
                return Ok(found.clone());
            }
        }
        if windows.len() == 1 {
            return Ok(windows[0].clone());
        }
        let titles: Vec<&str> = windows.iter().map(|(_, t)| t.as_str()).collect();
        Err(format!(
            "Several Roblox Studio windows are open and none matches; pick one with \
             studio_window action=restore title=<substring>. Open windows: {}",
            titles.join(" | ")
        ))
    }

    pub fn restore_studio_window(hint: Option<&str>) -> Result<String, String> {
        let (hwnd, title) = pick(&list_raw(), hint)?;
        unsafe {
            let hwnd = hwnd as HWND;
            if IsIconic(hwnd) != 0 {
                ShowWindow(hwnd, SW_RESTORE);
            }
            SetForegroundWindow(hwnd);
            if GetForegroundWindow() != hwnd {
                // Windows refuses foreground changes from background processes
                // unless an input event was just synthesized; tapping Alt
                // unlocks SetForegroundWindow (classic documented workaround).
                keybd_event(VK_MENU as u8, 0, 0, 0);
                keybd_event(VK_MENU as u8, 0, KEYEVENTF_KEYUP, 0);
                SetForegroundWindow(hwnd);
            }
        }
        Ok(title)
    }
}

#[cfg(not(target_os = "windows"))]
mod imp {
    use super::StudioWindowInfo;

    const UNSUPPORTED: &str =
        "Window control is only implemented on Windows in this build; bring the Roblox Studio \
         window to the front manually.";

    pub fn studio_windows() -> Result<Vec<StudioWindowInfo>, String> {
        Err(UNSUPPORTED.to_string())
    }

    pub fn restore_studio_window(_hint: Option<&str>) -> Result<String, String> {
        Err(UNSUPPORTED.to_string())
    }
}

pub use imp::{restore_studio_window, studio_windows};
