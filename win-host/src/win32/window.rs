use crate::proto::WindowInfo;
use anyhow::{ensure, Context, Result};
use std::{
    collections::HashMap,
    io, mem,
    path::Path,
    ptr,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HWND, LPARAM, POINT, RECT},
    Graphics::{
        Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS},
        Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTOPRIMARY},
    },
    System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
    },
    UI::{
        HiDpi::{GetDpiForMonitor, GetDpiForWindow, MDT_EFFECTIVE_DPI},
        WindowsAndMessaging::*,
    },
};

/// Reserved synthetic window ID representing the full primary Windows desktop monitor.
pub const DESKTOP_WINDOW_ID: u64 = 0xFFFF_FFFF_FFFF_0001;

pub fn primary_desktop_info() -> Result<WindowInfo> {
    unsafe {
        let monitor = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        ensure!(
            !monitor.is_null(),
            "DISPLAY_DISCONNECTED: no active primary monitor"
        );
        let mut mi: MONITORINFO = mem::zeroed();
        mi.cbSize = mem::size_of::<MONITORINFO>() as u32;
        ensure!(
            GetMonitorInfoW(monitor, &mut mi) != 0,
            "DISPLAY_DISCONNECTED: GetMonitorInfoW failed"
        );
        let r = mi.rcMonitor;
        let w = r.right.saturating_sub(r.left);
        let h = r.bottom.saturating_sub(r.top);
        ensure!(w > 0 && h > 0, "empty primary monitor dimensions");
        let mut dx = 96u32;
        let mut dy = 96u32;
        let _ = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
        Ok(WindowInfo {
            window_id: DESKTOP_WINDOW_ID,
            owner_window_id: 0,
            pid: 0,
            process_name: "desktop".into(),
            title: "Windows 桌面 (主显示器)".into(),
            kind: 1,
            x: r.left,
            y: r.top,
            width: w as u32,
            height: h as u32,
            dpi: dx.max(96),
            is_resizable: true,
            ..Default::default()
        })
    }
}

pub fn foreground_id() -> u64 {
    unsafe { GetForegroundWindow() as usize as u64 }
}
pub(crate) fn checked_hwnd(id: u64) -> Result<HWND> {
    let hwnd = usize::try_from(id)? as HWND;
    ensure!(
        !hwnd.is_null() && unsafe { IsWindow(hwnd) } != 0,
        "window 0x{id:x} no longer exists"
    );
    Ok(hwnd)
}

fn rects(hwnd: HWND) -> Result<(RECT, RECT)> {
    unsafe {
        let mut outer: RECT = mem::zeroed();
        if GetWindowRect(hwnd, &mut outer) == 0 {
            return Err(io::Error::last_os_error()).context("GetWindowRect");
        }
        let mut visible = outer;
        if DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS as u32,
            (&mut visible as *mut RECT).cast(),
            mem::size_of::<RECT>() as u32,
        ) < 0
        {
            visible = outer;
        }
        Ok((outer, visible))
    }
}

fn title(hwnd: HWND) -> String {
    unsafe {
        let mut buf = vec![0; (GetWindowTextLengthW(hwnd).clamp(0, 32767) + 1) as usize];
        let n = GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32);
        String::from_utf16_lossy(&buf[..n as usize])
    }
}
fn class(hwnd: HWND) -> String {
    let mut buf = [0; 256];
    let n = unsafe { GetClassNameW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
    String::from_utf16_lossy(&buf[..n as usize])
}
static PROCESS_NAME_CACHE: OnceLock<Mutex<HashMap<u32, (Instant, String)>>> = OnceLock::new();
const PROCESS_NAME_CACHE_TTL: Duration = Duration::from_secs(60);

pub(crate) fn process_name(pid: u32) -> String {
    if pid == 0 {
        return String::new();
    }
    let cache = PROCESS_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let now = Instant::now();
    if let Ok(guard) = cache.lock() {
        if let Some((ts, name)) = guard.get(&pid) {
            if now.duration_since(*ts) < PROCESS_NAME_CACHE_TTL {
                return name.clone();
            }
        }
    }
    let resolved = unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if h.is_null() {
            return String::new();
        }
        let mut buf = vec![0; 32768];
        let mut n = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, 0, buf.as_mut_ptr(), &mut n);
        CloseHandle(h);
        if ok == 0 {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buf[..n as usize]);
        Path::new(&path)
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned()
    };
    if !resolved.is_empty() {
        if let Ok(mut guard) = cache.lock() {
            if guard.len() >= 512 {
                guard.retain(|_, (ts, _)| now.duration_since(*ts) < PROCESS_NAME_CACHE_TTL);
            }
            guard.insert(pid, (now, resolved.clone()));
        }
    }
    resolved
}

/// Lightweight window geometry & owner/PID snapshot for high-frequency input injection.
/// Deliberately avoids `OpenProcess`, `GetWindowTextW`, and `GetClassNameW` so moving the
/// pointer over anti-automation sensitive apps (e.g. WeChat) never spams process handles.
#[derive(Clone, Copy, Debug)]
pub(crate) struct FastWindowBounds {
    pub window_id: u64,
    pub owner_window_id: u64,
    pub pid: u32,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

pub(crate) fn fast_bounds(id: u64) -> Result<FastWindowBounds> {
    let hwnd = checked_hwnd(id)?;
    unsafe {
        ensure!(IsWindowVisible(hwnd) != 0, "window is hidden");
        let (_, r) = rects(hwnd)?;
        let w = r.right.saturating_sub(r.left);
        let h = r.bottom.saturating_sub(r.top);
        ensure!(w > 0 && h > 0, "empty window bounds");
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        ensure!(pid != 0, "window no longer exists");
        let owner = GetWindow(hwnd, GW_OWNER);
        Ok(FastWindowBounds {
            window_id: id,
            owner_window_id: owner as usize as u64,
            pid,
            x: r.left,
            y: r.top,
            width: w as u32,
            height: h as u32,
        })
    }
}

pub fn info(id: u64) -> Result<WindowInfo> {
    let hwnd = checked_hwnd(id)?;
    unsafe {
        ensure!(IsWindowVisible(hwnd) != 0, "window is hidden");
        let mut cloaked = 0u32;
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_CLOAKED as u32,
            (&mut cloaked as *mut u32).cast(),
            4,
        );
        ensure!(cloaked == 0, "window is cloaked");
        let name = class(hwnd);
        ensure!(
            !matches!(
                name.as_str(),
                "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd"
            ),
            "desktop shell window"
        );
        let (_, r) = rects(hwnd)?;
        let w = r.right.saturating_sub(r.left);
        let h = r.bottom.saturating_sub(r.top);
        ensure!(w > 0 && h > 0, "empty window bounds");
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        ensure!(pid != 0, "window no longer exists");
        let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
        let ex = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        let owner = GetWindow(hwnd, GW_OWNER);
        let owner_rect = if owner.is_null() {
            None
        } else {
            rects(owner).ok().map(|(_, r)| r)
        };
        let title = title(hwnd);
        let has_caption = style & WS_CAPTION == WS_CAPTION;
        let kind = if name == "#32770" || (!owner.is_null() && has_caption) {
            2
        } else if matches!(name.as_str(), "#32768" | "ComboLBox" | "tooltips_class32")
            || ex & WS_EX_TOOLWINDOW != 0
            || (style & WS_POPUP != 0 && (!owner.is_null() || (title.is_empty() && !has_caption)))
        {
            3
        } else {
            1
        };
        Ok(WindowInfo {
            window_id: id,
            owner_window_id: owner as usize as u64,
            pid,
            process_name: process_name(pid),
            title,
            kind,
            x: r.left,
            y: r.top,
            width: w as u32,
            height: h as u32,
            offset_x: owner_rect.map_or(0, |o| r.left.saturating_sub(o.left)),
            offset_y: owner_rect.map_or(0, |o| r.top.saturating_sub(o.top)),
            dpi: GetDpiForWindow(hwnd),
            is_minimized: IsIconic(hwnd) != 0,
            is_maximized: IsZoomed(hwnd) != 0,
            is_resizable: style & WS_THICKFRAME != 0,
            has_alpha: ex & WS_EX_LAYERED != 0,
            ..Default::default()
        })
    }
}
pub fn candidates() -> Result<Vec<WindowInfo>> {
    unsafe extern "system" fn collect(hwnd: HWND, param: LPARAM) -> i32 {
        (*(param as *mut Vec<u64>)).push(hwnd as usize as u64);
        1
    }
    let mut ids = Vec::<u64>::new();
    if unsafe { EnumWindows(Some(collect), (&mut ids as *mut Vec<u64>) as LPARAM) } == 0 {
        return Err(io::Error::last_os_error()).context("EnumWindows");
    }
    let count = ids.len();
    Ok(ids
        .into_iter()
        .enumerate()
        .filter_map(|(i, id)| {
            let mut win = info(id).ok()?;
            win.z_order = (count - i) as u32;
            Some(win)
        })
        .collect())
}

pub fn list(include_icons: bool) -> Result<Vec<WindowInfo>> {
    let mut windows: Vec<_> = candidates()?
        .into_iter()
        .filter(|w| w.kind != 3 && (!w.title.is_empty() || w.owner_window_id == 0))
        .collect();
    if include_icons {
        for win in &mut windows {
            win.icon_png =
                super::image::app_icon(win.window_id as usize as HWND).unwrap_or_default();
        }
    }
    Ok(windows)
}

pub(crate) fn resize(id: u64, width: u32, height: u32) -> Result<WindowInfo> {
    ensure!(
        width > 0 && height > 0,
        "resize dimensions must be positive"
    );
    let hwnd = checked_hwnd(id)?;
    let (outer, visible) = rects(hwnd)?;
    let extent = |target: u32, a: i32, b: i32, c: i32, d: i32| -> Result<i32> {
        let size = i64::from(target) + i64::from(b) - i64::from(a) - i64::from(d) + i64::from(c);
        ensure!(size > 0, "invalid window dimensions");
        Ok(size.try_into()?)
    };
    let w = extent(width, outer.left, outer.right, visible.left, visible.right)?;
    let h = extent(height, outer.top, outer.bottom, visible.top, visible.bottom)?;
    if unsafe {
        SetWindowPos(
            hwnd,
            ptr::null_mut(),
            0,
            0,
            w,
            h,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
        )
    } == 0
    {
        return Err(io::Error::last_os_error()).context("SetWindowPos");
    }
    info(id)
}

/// Gently restores a minimized window so WGC capture can immediately produce live frames.
pub fn restore_if_minimized(id: u64) -> bool {
    if id == DESKTOP_WINDOW_ID {
        return false;
    }
    let Ok(hwnd) = checked_hwnd(id) else {
        return false;
    };
    unsafe {
        if IsIconic(hwnd) != 0 {
            let _ = ShowWindowAsync(hwnd, SW_RESTORE);
            return true;
        }
    }
    false
}
