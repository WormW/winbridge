mod apps;
pub use apps::{discover_apps, launch_shortcut};
mod clipboard;
mod cursor;
pub mod desktop;
mod event_hook;
pub use event_hook::{Event, Observer};
pub mod files;
mod image;
pub mod notifications;
pub mod tray;
mod window;
mod zip_pack;
pub(crate) use cursor::{is_cursor_currently_hidden, is_cursor_tracker_active};
pub(crate) use image::is_cursor_handle_transparent;
pub use window::{
    candidates, foreground_id, info, list, primary_desktop_info, restore_if_minimized,
    DESKTOP_WINDOW_ID,
};
pub(crate) use window::{checked_hwnd, fast_bounds, process_name, resize, FastWindowBounds};

pub fn init_dpi() {
    use windows_sys::Win32::UI::HiDpi::*;
    unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
}
