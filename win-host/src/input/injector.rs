use super::{foreground, hid_scancode::scancode, keyboard, send, text};
use crate::{
    proto::{control_message::Payload, FocusWindow, MouseEvent, WindowInfo, WindowUpdated},
    win32::{self, FastWindowBounds},
};
use anyhow::{bail, ensure, Context, Result};
use std::{
    collections::{BTreeSet, HashMap, HashSet},
    io, mem, ptr,
    sync::mpsc as sync,
    time::{Duration, Instant},
};
use tokio::sync::oneshot;
use windows_sys::Win32::{
    Foundation::{CloseHandle, GetLastError, ERROR_ACCESS_DENIED, HANDLE, POINT},
    Security::*,
    System::Threading::*,
    UI::{Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
};

type Reply = oneshot::Sender<Result<Option<WindowUpdated>>>;
pub struct Injector {
    tx: Option<sync::Sender<(WindowInfo, Payload, Reply)>>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Injector {
    pub fn new() -> Result<Self> {
        let (tx, rx) = sync::channel::<(WindowInfo, Payload, Reply)>();
        let thread = std::thread::Builder::new()
            .name("window-input".into())
            .spawn(move || {
                let mut state = State::default();
                for (target, payload, reply) in rx {
                    if !reply.is_closed() {
                        let _ = reply.send(state.apply(&target, payload));
                    }
                }
            })?;
        Ok(Self {
            tx: Some(tx),
            thread: Some(thread),
        })
    }
    pub async fn execute(
        &self,
        target: &WindowInfo,
        payload: Payload,
    ) -> Result<Option<WindowUpdated>> {
        let (tx, rx) = oneshot::channel();
        self.tx
            .as_ref()
            .context("input thread closed")?
            .send((target.clone(), payload, tx))
            .map_err(|_| anyhow::anyhow!("input thread closed"))?;
        rx.await?
    }
}
impl Drop for Injector {
    fn drop(&mut self) {
        drop(self.tx.take());
        if let Some(handle) = self.thread.take() {
            if tokio::runtime::Handle::try_current()
                .is_ok_and(|rt| rt.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread)
            {
                let _ = tokio::task::block_in_place(|| handle.join());
            } else {
                let _ = handle.join();
            }
        }
    }
}

fn elevated(process: HANDLE) -> Option<bool> {
    unsafe {
        let mut token = ptr::null_mut();
        if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 {
            return None;
        }
        let mut result: TOKEN_ELEVATION = mem::zeroed();
        let mut n = 0;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            (&mut result as *mut TOKEN_ELEVATION).cast(),
            mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut n,
        );
        CloseHandle(token);
        (ok != 0).then_some(result.TokenIsElevated != 0)
    }
}
fn check_access(pid: u32) -> Result<()> {
    unsafe {
        let proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if !proc.is_null() {
            let is_elevated = elevated(proc);
            CloseHandle(proc);
            ensure!(
                is_elevated != Some(true) || elevated(GetCurrentProcess()) != Some(false),
                "ACCESS_DENIED_ELEVATED: window runs with administrative privileges"
            );
        }
    }
    Ok(())
}

/// Returns true when the target process is elevated OR protected (e.g. anti-cheat stripping
/// `OpenProcess`/`OpenProcessToken` rights from a medium-integrity user session worker),
/// so input should be routed via the `LocalSystem + TokenUIAccess=1` secure-helper.
fn needs_privileged_helper(pid: u32) -> bool {
    unsafe {
        let proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if proc.is_null() {
            return GetLastError() == ERROR_ACCESS_DENIED;
        }
        let target_elevated = elevated(proc);
        CloseHandle(proc);
        target_elevated != Some(false) && elevated(GetCurrentProcess()) == Some(false)
    }
}

const ACCESS_CACHE_TTL: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AccessStatus {
    Standard,
    ElevatedOrProtected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DragAnchor {
    window_id: u64,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
}

const MAX_RAW_ASSIST_STEP: i32 = 16;

/// Anti-automation / IM apps that should stay strictly on `SetCursorPos` for pointer movement
/// (never emitting `SendInput(MOUSEEVENTF_MOVE)` streams into `WH_MOUSE_LL`).
fn is_setcursorpos_only_process(process_name: &str) -> bool {
    matches!(
        process_name.to_ascii_lowercase().as_str(),
        "weixin.exe"
            | "wechat.exe"
            | "wechatappex.exe"
            | "wechatplayer.exe"
            | "wechatbrowser.exe"
            | "qq.exe"
            | "tim.exe"
            | "wxwork.exe"
            | "dingtalk.exe"
            | "feishu.exe"
            | "lark.exe"
    )
}

/// Computes a bounded `(pre_pos, relative_step)` pair strictly inside `[min_bound, max_bound]`
/// so `SetCursorPos(pre)` + `SendInput(MOUSEEVENTF_MOVE, step)` emits genuine `MOUSE_MOVE_RELATIVE`
/// `WM_INPUT` (waking Unity / DirectInput in-game software cursors) while guaranteeing the cursor
/// never escapes the target window even under 2x Windows pointer acceleration.
fn bounded_raw_step(cur: i32, dst: i32, min_bound: i32, max_bound: i32) -> (i32, i32) {
    let delta = dst.saturating_sub(cur);
    if delta == 0 || max_bound <= min_bound || dst < min_bound || dst > max_bound {
        return (dst, 0);
    }
    if delta > 0 {
        let room_behind = dst.saturating_sub(min_bound);
        if room_behind <= 0 {
            return (dst, 0);
        }
        let room_ahead_safe = (max_bound.saturating_sub(dst) / 2).max(1);
        let step = delta
            .min(MAX_RAW_ASSIST_STEP)
            .min(room_behind)
            .min(room_ahead_safe);
        (dst.saturating_sub(step), step)
    } else {
        let mag = delta.saturating_neg();
        let room_behind = max_bound.saturating_sub(dst);
        if room_behind <= 0 {
            return (dst, 0);
        }
        let room_ahead_safe = (dst.saturating_sub(min_bound) / 2).max(1);
        let step = mag
            .min(MAX_RAW_ASSIST_STEP)
            .min(room_behind)
            .min(room_ahead_safe);
        (dst.saturating_add(step), -step)
    }
}

#[derive(Default)]
struct State {
    keys: BTreeSet<u32>,
    buttons: BTreeSet<i32>,
    wheel: [f64; 2],
    rel_mouse: [f64; 2],
    drag_anchor: Option<DragAnchor>,
    access_cache: HashMap<u32, (Instant, AccessStatus)>,
    wm_input_windows: HashSet<u64>,
    transparent_cursor_cache: HashMap<usize, bool>,
}
impl Drop for State {
    fn drop(&mut self) {
        let _ = win32::desktop::sync_thread_desktop();
        for &hid in &self.keys {
            if let Ok(key) = key_input(hid, false) {
                let _ = send(&[key]);
            }
        }
        for &btn in &self.buttons {
            if let Ok(up) = button(btn, false) {
                let _ = send(&[up]);
            }
        }
    }
}

fn mouse(flags: u32, data: u32, dx: i32, dy: i32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: data,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}
fn button(btn: i32, down: bool) -> Result<INPUT> {
    let (on, off, data) = match btn {
        1 => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, 0),
        2 => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, 0),
        3 => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, 0),
        4 => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 1),
        5 => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 2),
        _ => bail!("unsupported mouse button"),
    };
    Ok(mouse(if down { on } else { off }, data, 0, 0))
}

fn screen_pixel_axis(position: i32, size: u32, norm: f32) -> Result<i32> {
    ensure!(norm.is_finite(), "invalid screen pixel coordinates");
    let mut pixel = f64::from(position) + (f64::from(norm) * f64::from(size)).round();
    // On the exact trailing edge select the final pixel inside the window.
    if norm == 1.0 && size > 0 {
        pixel -= 1.0;
    }
    Ok(pixel.clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32)
}

fn virtual_axis(position: i32, size: u32, norm: f32, origin: i32, extent: i32) -> Result<i32> {
    ensure!(
        norm.is_finite() && extent > 0,
        "invalid virtual desktop coordinates"
    );
    let pixel = f64::from(position) + (f64::from(norm) * f64::from(size)).round();
    // On the exact trailing edge select the final pixel inside the window.
    let pixel = if norm == 1.0 { pixel - 1.0 } else { pixel };
    Ok(
        ((pixel - f64::from(origin)) * 65535.0 / f64::from((extent - 1).max(1)))
            .round()
            .clamp(0., 65535.) as i32,
    )
}
fn key_input(hid: u32, down: bool) -> Result<INPUT> {
    if hid == 0x48 {
        // Pause uses a multi-byte E1 sequence and has no Set-1 keyup.
        return Ok(INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VK_PAUSE,
                    wScan: 0,
                    dwFlags: if down { 0 } else { KEYEVENTF_KEYUP },
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        });
    }
    let (scan, extended) = scancode(hid).context("unsupported HID keyboard usage")?;
    Ok(keyboard(
        scan,
        KEYEVENTF_SCANCODE
            | if extended { KEYEVENTF_EXTENDEDKEY } else { 0 }
            | if down { 0 } else { KEYEVENTF_KEYUP },
    ))
}

#[derive(Default)]
pub(crate) struct DirectExecutor(State);

impl DirectExecutor {
    pub(crate) fn apply_privileged(
        &mut self,
        target_window_id: u64,
        payload: Payload,
    ) -> Result<Option<WindowUpdated>> {
        match win32::desktop::sync_thread_desktop() {
            Ok(on_secure) => self
                .0
                .apply_privileged_inner(target_window_id, payload, on_secure),
            Err(err) if err.to_string().contains("170") => {
                // ERROR_BUSY fallback: execute on a clean one-shot thread with zero desktop affinity.
                let handle = std::thread::Builder::new()
                    .name("secure-input-oneshot".into())
                    .spawn(move || -> Result<Option<WindowUpdated>> {
                        let _guard = win32::desktop::ThreadDesktopResetGuard::new();
                        let on_secure = win32::desktop::sync_thread_desktop()?;
                        let mut tmp = State::default();
                        let res = tmp.apply_privileged_inner(target_window_id, payload, on_secure);
                        // Don't emit synthetic keyups on oneshot drop.
                        tmp.keys.clear();
                        tmp.buttons.clear();
                        res
                    })?;
                handle
                    .join()
                    .map_err(|_| anyhow::anyhow!("secure-input-oneshot thread panicked"))?
            }
            Err(err) => Err(err),
        }
    }
}

impl State {
    fn lookup_access(&mut self, pid: u32, probe: impl FnOnce(u32) -> AccessStatus) -> AccessStatus {
        let now = Instant::now();
        if let Some((ts, status)) = self.access_cache.get(&pid) {
            if now.duration_since(*ts) < ACCESS_CACHE_TTL {
                return *status;
            }
        }
        let status = probe(pid);
        if self.access_cache.len() >= 256 {
            self.access_cache
                .retain(|_, (ts, _)| now.duration_since(*ts) < ACCESS_CACHE_TTL);
        }
        self.access_cache.insert(pid, (now, status));
        status
    }

    fn check_access_cached(&mut self, pid: u32) -> Result<()> {
        let status = self.lookup_access(pid, |p| {
            if check_access(p).is_err() {
                AccessStatus::ElevatedOrProtected
            } else {
                AccessStatus::Standard
            }
        });
        ensure!(
            status == AccessStatus::Standard,
            "ACCESS_DENIED_ELEVATED: window runs with administrative privileges"
        );
        Ok(())
    }

    fn needs_privileged_helper_cached(&mut self, pid: u32) -> bool {
        self.lookup_access(pid, |p| {
            if needs_privileged_helper(p) {
                AccessStatus::ElevatedOrProtected
            } else {
                AccessStatus::Standard
            }
        }) == AccessStatus::ElevatedOrProtected
    }

    fn resolve_pointer_rect(
        &mut self,
        target: FastWindowBounds,
        ev: &MouseEvent,
    ) -> (i32, i32, u32, u32) {
        if let Some(anchor) = self.drag_anchor {
            if anchor.window_id != target.window_id {
                self.drag_anchor = None;
            }
        }
        if ev.kind == 2 && ev.button == 1 && target.window_id != win32::DESKTOP_WINDOW_ID {
            self.drag_anchor = Some(DragAnchor {
                window_id: target.window_id,
                x: target.x,
                y: target.y,
                width: target.width,
                height: target.height,
            });
        }
        match self.drag_anchor {
            Some(anchor)
                if anchor.window_id == target.window_id
                    && (self.buttons.contains(&1) || (ev.kind == 3 && ev.button == 1)) =>
            {
                (anchor.x, anchor.y, anchor.width, anchor.height)
            }
            _ => (target.x, target.y, target.width, target.height),
        }
    }

    fn collect_wheel_events(&mut self, ev: &MouseEvent) -> Result<Vec<INPUT>> {
        let mut events = Vec::new();
        for (i, (delta, flag)) in [
            (ev.wheel_delta_x, MOUSEEVENTF_HWHEEL),
            (ev.wheel_delta_y, MOUSEEVENTF_WHEEL),
        ]
        .into_iter()
        .enumerate()
        {
            ensure!(delta.is_finite(), "non-finite wheel delta");
            let sum = self.wheel[i] + f64::from(delta);
            let amount = sum.round().clamp(i32::MIN as f64, i32::MAX as f64) as i32;
            self.wheel[i] = sum - sum.round();
            if amount != 0 {
                events.push(mouse(flag, amount as u32, 0, 0));
            }
        }
        Ok(events)
    }

    fn is_cursor_hidden_now(&mut self) -> bool {
        if win32::is_cursor_tracker_active() {
            return win32::is_cursor_currently_hidden();
        }
        unsafe {
            let mut ci: CURSORINFO = mem::zeroed();
            ci.cbSize = mem::size_of::<CURSORINFO>() as u32;
            if GetCursorInfo(&mut ci) == 0 {
                return false;
            }
            if (ci.flags & (CURSOR_SHOWING | CURSOR_SUPPRESSED)) == 0 || ci.hCursor.is_null() {
                return true;
            }
            let key = ci.hCursor as usize;
            if let Some(&cached) = self.transparent_cursor_cache.get(&key) {
                return cached;
            }
            let transparent = win32::is_cursor_handle_transparent(ci.hCursor);
            if self.transparent_cursor_cache.len() >= 128 {
                self.transparent_cursor_cache.clear();
            }
            self.transparent_cursor_cache.insert(key, transparent);
            transparent
        }
    }

    fn should_use_raw_input_move(
        &mut self,
        target: FastWindowBounds,
        allow_raw_move: bool,
    ) -> bool {
        if !allow_raw_move {
            return false;
        }
        let is_desktop = target.window_id == win32::DESKTOP_WINDOW_ID;
        if !is_desktop && self.wm_input_windows.contains(&target.window_id) {
            return true;
        }
        if !self.is_cursor_hidden_now() {
            return false;
        }
        let pid = if is_desktop {
            unsafe {
                let mut pt: POINT = mem::zeroed();
                if GetCursorPos(&mut pt) != 0 {
                    let hwnd = WindowFromPoint(pt);
                    let mut p = 0u32;
                    if !hwnd.is_null() {
                        GetWindowThreadProcessId(hwnd, &mut p);
                    }
                    p
                } else {
                    0
                }
            }
        } else {
            target.pid
        };
        if pid != 0 && is_setcursorpos_only_process(&win32::process_name(pid)) {
            return false;
        }
        if !is_desktop {
            if self.wm_input_windows.len() >= 128 {
                self.wm_input_windows.clear();
            }
            self.wm_input_windows.insert(target.window_id);
            tracing::info!(
                window_id = target.window_id,
                pid = target.pid,
                "detected hidden OS cursor; enabling WM_INPUT-assisted pointer movement"
            );
        }
        true
    }

    fn mouse(
        &mut self,
        target: FastWindowBounds,
        ev: MouseEvent,
        on_secure_desktop: bool,
        allow_raw_move: bool,
    ) -> Result<()> {
        unsafe {
            // Pure relative pointer movement (3D game Mouse Lock mode): inject raw relative
            // MOUSEEVENTF_MOVE (without ABSOLUTE/VIRTUALDESK) with sub-pixel accumulation.
            if ev.kind == 5 {
                self.drag_anchor = None;
                ensure!(
                    ev.delta_x.is_finite() && ev.delta_y.is_finite(),
                    "non-finite relative mouse delta"
                );
                let sum_x = self.rel_mouse[0] + f64::from(ev.delta_x);
                let sum_y = self.rel_mouse[1] + f64::from(ev.delta_y);
                let dx = sum_x.round().clamp(i32::MIN as f64, i32::MAX as f64) as i32;
                let dy = sum_y.round().clamp(i32::MIN as f64, i32::MAX as f64) as i32;
                self.rel_mouse[0] = sum_x - sum_x.round();
                self.rel_mouse[1] = sum_y - sum_y.round();
                if dx != 0 || dy != 0 {
                    send(&[mouse(MOUSEEVENTF_MOVE, 0, dx, dy)])?;
                }
                return Ok(());
            }

            // In-place button / wheel injection while Mouse Lock is active (never warp cursor).
            if ev.is_relative {
                self.drag_anchor = None;
                let mut events = Vec::new();
                match ev.kind {
                    1 => {}
                    2 | 3 => events.push(button(ev.button, ev.kind == 2)?),
                    4 => events.extend(self.collect_wheel_events(&ev)?),
                    _ => bail!("unsupported relative mouse event"),
                }
                if !events.is_empty() {
                    send(&events)?;
                }
                match ev.kind {
                    2 => {
                        self.buttons.insert(ev.button);
                    }
                    3 => {
                        self.buttons.remove(&ev.button);
                    }
                    _ => {}
                }
                return Ok(());
            }

            if on_secure_desktop {
                // On Winlogon / UAC consent.exe, use SendInput absolute coordinates and split
                // move + click so hover hit-testing settles cleanly on the secure desktop.
                self.drag_anchor = None;
                let dx = virtual_axis(
                    target.x,
                    target.width,
                    ev.norm_x,
                    GetSystemMetrics(SM_XVIRTUALSCREEN),
                    GetSystemMetrics(SM_CXVIRTUALSCREEN),
                )?;
                let dy = virtual_axis(
                    target.y,
                    target.height,
                    ev.norm_y,
                    GetSystemMetrics(SM_YVIRTUALSCREEN),
                    GetSystemMetrics(SM_CYVIRTUALSCREEN),
                )?;
                let move_ev = mouse(
                    MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                    0,
                    dx,
                    dy,
                );
                if matches!(ev.kind, 2 | 3) {
                    send(&[move_ev])?;
                    if ev.kind == 2 {
                        std::thread::sleep(std::time::Duration::from_millis(3));
                    }
                    send(&[button(ev.button, ev.kind == 2)?])?;
                    if ev.kind == 2 {
                        tracing::info!(
                            button = ev.button,
                            norm_x = ev.norm_x,
                            norm_y = ev.norm_y,
                            dx,
                            dy,
                            "injected secure-desktop mouse click"
                        );
                    }
                } else {
                    let mut events = vec![move_ev];
                    match ev.kind {
                        1 => {}
                        4 => events.extend(self.collect_wheel_events(&ev)?),
                        _ => bail!("unsupported mouse event"),
                    }
                    send(&events)?;
                }
            } else {
                // Standard desktop & application windows: default to SetCursorPos so anti-automation
                // IM apps (e.g. WeChat) never see LLMHF_INJECTED move floods. When a game hides the
                // Windows OS cursor (drawing its own Unity/DirectInput software cursor that only wakes
                // on WM_INPUT), emit a bounded relative MOUSEEVENTF_MOVE step and snap to exact (px, py).
                let (map_x, map_y, map_w, map_h) = self.resolve_pointer_rect(target, &ev);
                let px = screen_pixel_axis(map_x, map_w, ev.norm_x)?;
                let py = screen_pixel_axis(map_y, map_h, ev.norm_y)?;
                let mut cur: POINT = mem::zeroed();
                let got_cur = GetCursorPos(&mut cur) != 0;
                if !got_cur || cur.x != px || cur.y != py {
                    if self.should_use_raw_input_move(target, allow_raw_move) {
                        let min_x = map_x;
                        let max_x = map_x.saturating_add(
                            i32::try_from(map_w).unwrap_or(i32::MAX).saturating_sub(1),
                        );
                        let min_y = map_y;
                        let max_y = map_y.saturating_add(
                            i32::try_from(map_h).unwrap_or(i32::MAX).saturating_sub(1),
                        );
                        let (pre_x, step_x) = if got_cur {
                            bounded_raw_step(cur.x, px, min_x, max_x)
                        } else {
                            (px, 0)
                        };
                        let (pre_y, step_y) = if got_cur {
                            bounded_raw_step(cur.y, py, min_y, max_y)
                        } else {
                            (py, 0)
                        };
                        if step_x != 0 || step_y != 0 {
                            if cur.x != pre_x || cur.y != pre_y {
                                let _ = SetCursorPos(pre_x, pre_y);
                            }
                            let _ = send(&[mouse(MOUSEEVENTF_MOVE, 0, step_x, step_y)]);
                            let mut after: POINT = mem::zeroed();
                            if GetCursorPos(&mut after) == 0 || after.x != px || after.y != py {
                                let _ = SetCursorPos(px, py);
                            }
                        } else {
                            let _ = SetCursorPos(px, py);
                        }
                    } else {
                        let _ = SetCursorPos(px, py);
                    }
                }
                match ev.kind {
                    1 => {}
                    2 | 3 => send(&[button(ev.button, ev.kind == 2)?])?,
                    4 => {
                        let events = self.collect_wheel_events(&ev)?;
                        if !events.is_empty() {
                            send(&events)?;
                        }
                    }
                    _ => bail!("unsupported mouse event"),
                }
            }
            match ev.kind {
                2 => {
                    self.buttons.insert(ev.button);
                }
                3 => {
                    self.buttons.remove(&ev.button);
                    if ev.button == 1 {
                        self.drag_anchor = None;
                    }
                }
                _ => {
                    if !self.buttons.contains(&1) {
                        self.drag_anchor = None;
                    }
                }
            }
            Ok(())
        }
    }

    fn apply_desktop(
        &mut self,
        payload: Payload,
        on_secure_desktop: bool,
    ) -> Result<Option<WindowUpdated>> {
        let desktop = if on_secure_desktop {
            // On Winlogon, primary screen metrics match the captured GDI desktop directly.
            let w = unsafe { GetSystemMetrics(SM_CXSCREEN) }.max(1) as u32;
            let h = unsafe { GetSystemMetrics(SM_CYSCREEN) }.max(1) as u32;
            FastWindowBounds {
                window_id: win32::DESKTOP_WINDOW_ID,
                owner_window_id: 0,
                pid: 0,
                x: 0,
                y: 0,
                width: w,
                height: h,
            }
        } else {
            let info = win32::primary_desktop_info()?;
            FastWindowBounds {
                window_id: win32::DESKTOP_WINDOW_ID,
                owner_window_id: 0,
                pid: 0,
                x: info.x,
                y: info.y,
                width: info.width,
                height: info.height,
            }
        };
        match payload {
            Payload::MouseEvent(ev) => self.mouse(desktop, ev, on_secure_desktop, true)?,
            Payload::KeyEvent(ev) => {
                send(&[key_input(ev.hid_usage, ev.is_down)?])?;
                if ev.is_down {
                    self.keys.insert(ev.hid_usage);
                } else {
                    self.keys.remove(&ev.hid_usage);
                }
            }
            Payload::TextInput(t) => text(&t.text)?,
            Payload::ResizeWindow(_)
            | Payload::FocusWindow(_)
            | Payload::CloseWindow(_)
            | Payload::WindowAction(_) => {}
            _ => bail!("unsupported input command"),
        }
        Ok(None)
    }

    fn apply_privileged_inner(
        &mut self,
        target_window_id: u64,
        payload: Payload,
        on_secure_desktop: bool,
    ) -> Result<Option<WindowUpdated>> {
        if target_window_id == win32::DESKTOP_WINDOW_ID {
            return self.apply_desktop(payload, on_secure_desktop);
        }
        if on_secure_desktop {
            bail!("UAC 安全桌面当前已激活，请在自动弹出的 Windows 桌面窗口中点击确认");
        }
        let current = win32::fast_bounds(target_window_id)?;
        let hwnd = win32::checked_hwnd(current.window_id)?;
        let focus = || -> Result<()> {
            let style = unsafe { GetWindowLongW(hwnd, GWL_STYLE) as u32 };
            let is_popup = current.owner_window_id != 0
                && (style & WS_POPUP != 0)
                && (style & WS_CAPTION != WS_CAPTION);
            let owner = if is_popup {
                win32::checked_hwnd(current.owner_window_id)?
            } else {
                hwnd
            };
            foreground(owner)
        };
        self.apply_window_payload(current, hwnd, payload, true, focus)
    }

    fn apply_window_payload(
        &mut self,
        current: FastWindowBounds,
        hwnd: windows_sys::Win32::Foundation::HWND,
        payload: Payload,
        allow_raw_move: bool,
        focus: impl Fn() -> Result<()>,
    ) -> Result<Option<WindowUpdated>> {
        let focus_best_effort = || {
            if let Err(err) = focus() {
                // If an elevated window currently holds foreground, ask LocalSystem helper to switch focus.
                if crate::helper::is_configured() {
                    let req = Payload::FocusWindow(FocusWindow {
                        window_id: current.window_id,
                        focused: true,
                    });
                    if let Err(herr) = crate::helper::forward_input(current.window_id, &req) {
                        tracing::debug!(window_id = current.window_id, error = %herr, "helper focus fallback declined");
                    }
                } else {
                    tracing::debug!(window_id = current.window_id, error = %err, "foreground activation declined; injecting input anyway");
                }
            }
        };
        match payload {
            Payload::ResizeWindow(r) => {
                let window = win32::resize(current.window_id, r.width, r.height)?;
                return Ok(Some(WindowUpdated {
                    window: Some(window),
                    ack_resize_seq: r.resize_seq,
                }));
            }
            Payload::FocusWindow(r) => {
                if r.focused {
                    focus_best_effort();
                }
            }
            Payload::CloseWindow(_) => {
                if unsafe { PostMessageW(hwnd, WM_CLOSE, 0, 0) } == 0 {
                    return Err(io::Error::last_os_error()).context("WM_CLOSE");
                }
            }
            Payload::WindowAction(a) => match a.action {
                1 | 2 => unsafe {
                    ShowWindowAsync(
                        hwnd,
                        if a.action == 1 {
                            SW_MAXIMIZE
                        } else {
                            SW_RESTORE
                        },
                    );
                },
                3 => focus_best_effort(),
                _ => bail!("unknown window action"),
            },
            Payload::MouseEvent(ev) => {
                if ev.kind == 2 {
                    focus_best_effort();
                }
                self.mouse(current, ev, false, allow_raw_move)?;
            }
            Payload::KeyEvent(ev) => {
                focus_best_effort();
                send(&[key_input(ev.hid_usage, ev.is_down)?])?;
                if ev.is_down {
                    self.keys.insert(ev.hid_usage);
                } else {
                    self.keys.remove(&ev.hid_usage);
                }
            }
            Payload::TextInput(t) => {
                focus_best_effort();
                text(&t.text)?;
            }
            _ => bail!("unsupported input command"),
        }
        Ok(None)
    }

    fn apply(&mut self, target: &WindowInfo, payload: Payload) -> Result<Option<WindowUpdated>> {
        if crate::helper::is_configured() {
            if target.window_id == win32::DESKTOP_WINDOW_ID {
                return match payload {
                    Payload::MouseEvent(_) | Payload::KeyEvent(_) | Payload::TextInput(_) => {
                        crate::helper::forward_input(target.window_id, &payload)
                    }
                    Payload::ResizeWindow(_)
                    | Payload::FocusWindow(_)
                    | Payload::CloseWindow(_)
                    | Payload::WindowAction(_) => Ok(None),
                    _ => bail!("unsupported input command"),
                };
            }
            if win32::desktop::is_secure_desktop() {
                bail!("UAC 安全桌面当前已激活，请在自动弹出的 Windows 桌面窗口中点击确认");
            }
            let current = win32::fast_bounds(target.window_id)?;
            ensure!(current.pid == target.pid, "window handle has been reused");
            let hwnd = win32::checked_hwnd(current.window_id)?;
            if self.needs_privileged_helper_cached(current.pid) {
                // Target runs with Administrator privileges or anti-cheat handle protection;
                // forward to LocalSystem + UIAccess helper.
                return crate::helper::forward_input(target.window_id, &payload);
            }
            let focus = || -> Result<()> {
                let owner_id = if current.owner_window_id != 0 {
                    current.owner_window_id
                } else {
                    target.owner_window_id
                };
                let owner = if target.kind == 3 && owner_id != 0 {
                    win32::checked_hwnd(owner_id)?
                } else {
                    hwnd
                };
                foreground(owner)
            };
            let allow_raw_move = !is_setcursorpos_only_process(&target.process_name);
            return self.apply_window_payload(current, hwnd, payload, allow_raw_move, focus);
        }

        // Standalone non-service mode: sync local thread desktop directly.
        let on_secure_desktop = win32::desktop::sync_thread_desktop()?;
        if target.window_id == win32::DESKTOP_WINDOW_ID {
            return self.apply_desktop(payload, on_secure_desktop);
        }
        if on_secure_desktop {
            bail!("UAC 安全桌面当前已激活，请在自动弹出的 Windows 桌面窗口中点击确认");
        }
        let current = win32::fast_bounds(target.window_id)?;
        ensure!(current.pid == target.pid, "window handle has been reused");
        let hwnd = win32::checked_hwnd(current.window_id)?;
        self.check_access_cached(current.pid)?;
        let focus = || -> Result<()> {
            let owner_id = if current.owner_window_id != 0 {
                current.owner_window_id
            } else {
                target.owner_window_id
            };
            let owner = if target.kind == 3 && owner_id != 0 {
                win32::checked_hwnd(owner_id)?
            } else {
                hwnd
            };
            foreground(owner)
        };
        let allow_raw_move = !is_setcursorpos_only_process(&target.process_name);
        self.apply_window_payload(current, hwnd, payload, allow_raw_move, focus)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        bounded_raw_step, is_setcursorpos_only_process, screen_pixel_axis, virtual_axis,
        FastWindowBounds, MouseEvent, State,
    };

    #[test]
    fn negative_monitor_and_drag() {
        assert_eq!(virtual_axis(-1920, 1920, 0.0, -1920, 3840).unwrap(), 0);
        assert_eq!(virtual_axis(0, 1920, 1.0, -1920, 3840).unwrap(), 65535);
        assert!(
            virtual_axis(100, 800, -0.1, 0, 1920).unwrap()
                < virtual_axis(100, 800, 0.0, 0, 1920).unwrap()
        );
    }

    #[test]
    fn screen_pixel_axis_maps_edges_negative_monitors_and_overdrag() {
        assert_eq!(screen_pixel_axis(100, 800, 0.0).unwrap(), 100);
        assert_eq!(screen_pixel_axis(100, 800, 0.5).unwrap(), 500);
        assert_eq!(screen_pixel_axis(100, 800, 1.0).unwrap(), 899);
        assert_eq!(screen_pixel_axis(-1920, 1920, 0.0).unwrap(), -1920);
        assert_eq!(screen_pixel_axis(-1920, 1920, 1.0).unwrap(), -1);
        assert_eq!(screen_pixel_axis(100, 800, -0.1).unwrap(), 20);
        assert_eq!(screen_pixel_axis(100, 800, 1.25).unwrap(), 1100);
    }

    #[test]
    fn left_drag_anchor_prevents_window_move_feedback_jitter() {
        let mut state = State::default();
        let start = FastWindowBounds {
            window_id: 0x1234,
            owner_window_id: 0,
            pid: 99,
            x: 100,
            y: 200,
            width: 800,
            height: 600,
        };
        let down = MouseEvent {
            kind: 2,
            button: 1,
            norm_x: 0.5,
            norm_y: 0.05,
            ..Default::default()
        };
        assert_eq!(
            state.resolve_pointer_rect(start, &down),
            (100, 200, 800, 600)
        );
        state.buttons.insert(1);

        // Window has moved +120px on Windows while dragging; anchor must hold initial rect.
        let moved = FastWindowBounds {
            x: 220,
            y: 240,
            ..start
        };
        let drag = MouseEvent {
            kind: 1,
            button: 0,
            norm_x: 0.65,
            norm_y: 0.1,
            ..Default::default()
        };
        assert_eq!(
            state.resolve_pointer_rect(moved, &drag),
            (100, 200, 800, 600)
        );

        // Release still maps against the anchor, then clears after mouse-up handling.
        let up = MouseEvent {
            kind: 3,
            button: 1,
            norm_x: 0.65,
            norm_y: 0.1,
            ..Default::default()
        };
        assert_eq!(state.resolve_pointer_rect(moved, &up), (100, 200, 800, 600));
        state.buttons.remove(&1);
        state.drag_anchor = None;

        // Next hover uses the new live window bounds.
        assert_eq!(
            state.resolve_pointer_rect(moved, &drag),
            (220, 240, 800, 600)
        );
    }

    #[test]
    fn bounded_raw_step_emits_true_delta_inside_window_and_never_escapes_edges() {
        // Interior normal move (12px <= 16px): pre == cur, zero extra SetCursorPos needed!
        assert_eq!(bounded_raw_step(500, 512, 100, 2023), (500, 12));
        assert_eq!(bounded_raw_step(500, 490, 100, 2023), (500, -10));

        // Large jump (800px): caps step at 16px, pre stays strictly inside [100, 2023].
        assert_eq!(bounded_raw_step(200, 1000, 100, 2023), (984, 16));
        assert_eq!(bounded_raw_step(1800, 1000, 100, 2023), (1016, -16));

        // Near right edge (3px room ahead): caps step to 1px so 2x acceleration cannot escape.
        assert_eq!(bounded_raw_step(2010, 2020, 100, 2023), (2019, 1));
        // Near left edge (2px room ahead): caps step to -1px.
        assert_eq!(bounded_raw_step(115, 102, 100, 2023), (103, -1));

        // Out-of-bounds over-drag or zero delta returns step 0 (pure SetCursorPos fallback).
        assert_eq!(bounded_raw_step(500, 500, 100, 2023), (500, 0));
        assert_eq!(bounded_raw_step(500, 90, 100, 2023), (90, 0));
        assert_eq!(bounded_raw_step(500, 2050, 100, 2023), (2050, 0));
    }

    #[test]
    fn setcursorpos_only_process_protects_im_apps_and_allows_games() {
        assert!(is_setcursorpos_only_process("Weixin.exe"));
        assert!(is_setcursorpos_only_process("WeChat.exe"));
        assert!(is_setcursorpos_only_process("QQ.exe"));
        assert!(!is_setcursorpos_only_process("HeavenBurnsRed.exe"));
        assert!(!is_setcursorpos_only_process("Endfield.exe"));
    }
}
