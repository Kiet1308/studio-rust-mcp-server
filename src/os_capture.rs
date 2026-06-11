//! OS-level capture of the Roblox Studio window.
//!
//! Fallback for take_screenshot when the in-engine CaptureService path fails
//! (it has a known mode where the capture callback never fires, and it cannot
//! work at all while Studio is not rendering). This captures the whole Studio
//! window including its chrome, so pixel coordinates do NOT map to viewport
//! coordinates — callers are told via metadata.

use color_eyre::eyre::{eyre, Result};

pub struct WindowCapture {
    pub image: image::RgbaImage,
    pub title: String,
}

pub fn capture_studio_window() -> Result<WindowCapture> {
    let windows = xcap::Window::all().map_err(|e| eyre!("Could not enumerate windows: {e}"))?;

    let mut best: Option<(u64, xcap::Window, String)> = None;
    for window in windows {
        let title = window.title().unwrap_or_default();
        if !title.contains("Roblox Studio") {
            continue;
        }
        if window.is_minimized().unwrap_or(false) {
            continue;
        }
        let area = u64::from(window.width().unwrap_or(0)) * u64::from(window.height().unwrap_or(0));
        // Prefer the focused window; among the rest pick the largest. With
        // several Studio instances open this is a heuristic — the metadata
        // reports which window was captured.
        let score = if window.is_focused().unwrap_or(false) {
            u64::MAX
        } else {
            area
        };
        if best.as_ref().is_none_or(|(s, _, _)| score > *s) {
            best = Some((score, window, title));
        }
    }

    let (_, window, title) = best.ok_or_else(|| {
        eyre!("No visible Roblox Studio window found (it may be minimized or closed)")
    })?;

    let captured = window
        .capture_image()
        .map_err(|e| eyre!("Window capture failed: {e}"))?;

    // xcap may link its own copy of the image crate; convert through raw
    // bytes so the types line up regardless.
    let (width, height) = captured.dimensions();
    let raw = captured.into_raw();
    let image = image::RgbaImage::from_raw(width, height, raw)
        .ok_or_else(|| eyre!("Captured window image had unexpected buffer size"))?;

    Ok(WindowCapture { image, title })
}
