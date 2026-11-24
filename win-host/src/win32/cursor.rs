use super::{image::cursor_pixels, Event};
use crate::proto::CursorShape;
use std::{
    mem, ptr,
    sync::atomic::{AtomicBool, Ordering},
};
use tokio::sync::mpsc::Sender;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

static CURSOR_TRACKER_ACTIVE: AtomicBool = AtomicBool::new(false);
static CURSOR_CURRENTLY_HIDDEN: AtomicBool = AtomicBool::new(false);

pub(crate) fn is_cursor_tracker_active() -> bool {
    CURSOR_TRACKER_ACTIVE.load(Ordering::Acquire)
}

pub(crate) fn is_cursor_currently_hidden() -> bool {
    CURSOR_CURRENTLY_HIDDEN.load(Ordering::Acquire)
}

fn is_cursor_hidden_flags(flags: u32) -> bool {
    // Only treat the cursor as hidden when neither CURSOR_SHOWING (1) nor CURSOR_SUPPRESSED (2)
    // is set. CURSOR_SUPPRESSED happens during touch/typing suppression and is not cleared by
    // SetCursorPos, so treating it as hidden would make the Mac pointer vanish permanently.
    (flags & (CURSOR_SHOWING | CURSOR_SUPPRESSED)) == 0
}

pub(super) struct Tracker {
    standard: Vec<(HCURSOR, i32)>,
    last: Option<(u64, usize, u32)>,
}
impl Tracker {
    pub fn new() -> Self {
        let resources = [
            IDC_ARROW,
            IDC_IBEAM,
            IDC_HAND,
            IDC_CROSS,
            IDC_WAIT,
            IDC_APPSTARTING,
            IDC_SIZENS,
            IDC_SIZEWE,
            IDC_SIZENWSE,
            IDC_SIZENESW,
            IDC_SIZEALL,
            IDC_NO,
        ];
        let standard = resources
            .into_iter()
            .enumerate()
            .map(|(i, r)| (unsafe { LoadCursorW(ptr::null_mut(), r) }, i as i32 + 1))
            .filter(|(h, _)| !h.is_null())
            .collect();
        CURSOR_TRACKER_ACTIVE.store(true, Ordering::Release);
        Self {
            standard,
            last: None,
        }
    }
    pub fn sample(&mut self, events: &Sender<Event>) {
        unsafe {
            let mut ci: CURSORINFO = mem::zeroed();
            ci.cbSize = mem::size_of::<CURSORINFO>() as u32;
            if GetCursorInfo(&mut ci) == 0 {
                return;
            }
            let mut target = GetAncestor(WindowFromPoint(ci.ptScreenPos), GA_ROOT) as usize as u64;
            if target == 0 {
                target = GetForegroundWindow() as usize as u64;
            }
            let key = (target, ci.hCursor as usize, ci.flags);
            if self.last == Some(key) {
                return;
            }
            let mut shape = CursorShape {
                window_id: target,
                ..Default::default()
            };
            if is_cursor_hidden_flags(ci.flags) || ci.hCursor.is_null() {
                shape.cursor_type = 13;
            } else if let Some((_, kind)) = self.standard.iter().find(|(h, _)| *h == ci.hCursor) {
                shape.cursor_type = *kind;
            } else if let Some((rgba, w, h, x, y)) = cursor_pixels(ci.hCursor) {
                // Some 3D games hide the pointer using a fully transparent custom cursor.
                let all_transparent = rgba.chunks_exact(4).all(|px| px[3] == 0);
                if all_transparent {
                    tracing::debug!(
                        window_id = target,
                        w,
                        h,
                        flags = ci.flags,
                        "custom cursor is all-transparent -> hidden"
                    );
                    shape.cursor_type = 13;
                } else {
                    tracing::debug!(
                        window_id = target,
                        w,
                        h,
                        x,
                        y,
                        flags = ci.flags,
                        "forwarding custom cursor"
                    );
                    shape.cursor_type = 14;
                    shape.custom_rgba = rgba;
                    shape.width = w;
                    shape.height = h;
                    shape.hotspot_x = x;
                    shape.hotspot_y = y;
                }
            } else {
                tracing::debug!(
                    window_id = target,
                    flags = ci.flags,
                    "custom cursor pixel extraction failed -> arrow fallback"
                );
                shape.cursor_type = 1;
            }
            CURSOR_CURRENTLY_HIDDEN.store(shape.cursor_type == 13, Ordering::Release);
            if events.try_send(Event::Cursor(shape)).is_ok() {
                self.last = Some(key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_hidden_flags_respects_suppressed_state() {
        assert!(is_cursor_hidden_flags(0));
        assert!(!is_cursor_hidden_flags(CURSOR_SHOWING));
        assert!(!is_cursor_hidden_flags(CURSOR_SUPPRESSED));
        assert!(!is_cursor_hidden_flags(CURSOR_SHOWING | CURSOR_SUPPRESSED));
    }
}
