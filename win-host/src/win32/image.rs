use anyhow::{ensure, Result};
use std::{mem, ptr, slice};
use windows_sys::Win32::{Foundation::HWND, Graphics::Gdi::*, UI::WindowsAndMessaging::*};

/// Recovers straight RGBA from a GDI icon rendered onto black (0x00) and white (0xFF)
/// 32-bit DIB backgrounds, checking all three RGB channels so pure red/green/yellow
/// XOR-masked pixels are never misclassified as transparent.
fn recover_alpha_from_black_white(black: &mut [u8], white: &[u8]) {
    for (b, w) in black.chunks_exact_mut(4).zip(white.chunks_exact(4)) {
        let diff = w[0]
            .saturating_sub(b[0])
            .min(w[1].saturating_sub(b[1]))
            .min(w[2].saturating_sub(b[2]));
        let alpha = 255 - diff;
        b.swap(0, 2);
        if alpha > 0 {
            for c in &mut b[..3] {
                *c = ((u32::from(*c) * 255 / u32::from(alpha)).min(255)) as u8;
            }
        }
        b[3] = alpha;
    }
}

/// Converts a top-down 32-bit BGRA color cursor bitmap (and optional 1bpp mask expanded to 32-bit)
/// into straight RGBA pixels. Mirrors WebRTC's Windows cursor extraction so 32-bit ARGB game
/// cursors (e.g. Unity `Cursor.SetCursor` via `CreateIconIndirect`) are read directly without
/// GDI `DrawIconEx` alpha-loss quirks.
fn decode_color_cursor_bgra(color_bgra: &[u8], mask_bgra: Option<&[u8]>) -> Vec<u8> {
    let has_alpha = color_bgra.chunks_exact(4).any(|px| px[3] != 0);
    let mut out = Vec::with_capacity(color_bgra.len());
    if has_alpha {
        for px in color_bgra.chunks_exact(4) {
            out.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
        }
        return out;
    }
    if let Some(mask) = mask_bgra.filter(|m| m.len() == color_bgra.len()) {
        for (c, m) in color_bgra.chunks_exact(4).zip(mask.chunks_exact(4)) {
            let mask_transparent = m[0] != 0;
            if !mask_transparent {
                out.extend_from_slice(&[c[2], c[1], c[0], 255]);
            } else if c[0] == 0 && c[1] == 0 && c[2] == 0 {
                out.extend_from_slice(&[0, 0, 0, 0]);
            } else {
                // XOR-colored cursor pixel: render visibly as opaque color.
                out.extend_from_slice(&[c[2], c[1], c[0], 255]);
            }
        }
    } else {
        for c in color_bgra.chunks_exact(4) {
            out.extend_from_slice(&[c[2], c[1], c[0], 255]);
        }
    }
    out
}

/// Converts a top-down monochrome cursor mask (top half = AND plane, bottom half = XOR plane,
/// expanded to 32-bit BGRA by `GetDIBits`) into straight RGBA pixels.
fn decode_monochrome_cursor_mask(mask_bgra: &[u8], w: u32, h: u32) -> Option<Vec<u8>> {
    let half = (w as usize).checked_mul(h as usize)?.checked_mul(4)?;
    let total = half.checked_mul(2)?;
    if mask_bgra.len() < total {
        return None;
    }
    let (and_plane, xor_plane) = (&mask_bgra[..half], &mask_bgra[half..total]);
    let mut out = Vec::with_capacity(half);
    for (a, x) in and_plane.chunks_exact(4).zip(xor_plane.chunks_exact(4)) {
        let and_set = a[0] != 0;
        let xor_set = x[0] != 0;
        match (and_set, xor_set) {
            (false, false) => out.extend_from_slice(&[0, 0, 0, 255]),
            (false, true) => out.extend_from_slice(&[255, 255, 255, 255]),
            (true, false) => out.extend_from_slice(&[0, 0, 0, 0]),
            // Inverted XOR pixel: render visibly as opaque white.
            (true, true) => out.extend_from_slice(&[255, 255, 255, 255]),
        }
    }
    Some(out)
}

fn has_visible_pixel(rgba: &[u8]) -> bool {
    rgba.chunks_exact(4).any(|px| px[3] != 0)
}

fn scaled_cursor_dimensions(
    w: u32,
    h: u32,
    hx: u32,
    hy: u32,
    max_dim: u32,
) -> (u32, u32, u32, u32) {
    let largest = w.max(h);
    if largest <= max_dim || largest == 0 {
        return (w, h, hx, hy);
    }
    let scale = f64::from(max_dim) / f64::from(largest);
    let sw = ((f64::from(w) * scale).round() as u32).max(1);
    let sh = ((f64::from(h) * scale).round() as u32).max(1);
    let shx = ((f64::from(hx) * scale).round() as u32).min(sw.saturating_sub(1));
    let shy = ((f64::from(hy) * scale).round() as u32).min(sh.saturating_sub(1));
    (sw, sh, shx, shy)
}

unsafe fn read_dib_bgra(dc: HDC, hbm: HBITMAP, w: u32, rows: u32) -> Option<Vec<u8>> {
    let len = (w as usize).checked_mul(rows as usize)?.checked_mul(4)?;
    let width_i32 = i32::try_from(w).ok()?;
    let height_i32 = i32::try_from(rows).ok()?;
    let mut bmi: BITMAPINFO = mem::zeroed();
    bmi.bmiHeader.biSize = mem::size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = width_i32;
    bmi.bmiHeader.biHeight = -height_i32;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    let mut buf = vec![0u8; len];
    let copied = GetDIBits(
        dc,
        hbm,
        0,
        rows,
        buf.as_mut_ptr().cast(),
        &mut bmi,
        DIB_RGB_COLORS,
    );
    (copied > 0).then_some(buf)
}

/// Draw on black and white to recover alpha for both legacy AND masks and ARGB icons.
fn rgba(icon: HICON, w: u32, h: u32) -> Result<Vec<u8>> {
    ensure!(
        !icon.is_null() && (1..=256).contains(&w) && (1..=256).contains(&h),
        "invalid icon"
    );
    unsafe {
        let dc = CreateCompatibleDC(ptr::null_mut());
        ensure!(!dc.is_null(), "CreateCompatibleDC failed");
        let mut bmi: BITMAPINFO = mem::zeroed();
        bmi.bmiHeader.biSize = mem::size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = w as i32;
        bmi.bmiHeader.biHeight = -(h as i32);
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;
        let mut bits = ptr::null_mut();
        let bmp = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &mut bits, ptr::null_mut(), 0);
        if bmp.is_null() {
            DeleteDC(dc);
            anyhow::bail!("CreateDIBSection failed");
        }
        let old = SelectObject(dc, bmp);
        let len = w as usize * h as usize * 4;
        let render = |background: u8| -> Result<Vec<u8>> {
            ptr::write_bytes(bits.cast::<u8>(), background, len);
            ensure!(
                DrawIconEx(
                    dc,
                    0,
                    0,
                    icon,
                    w as i32,
                    h as i32,
                    0,
                    ptr::null_mut(),
                    DI_NORMAL
                ) != 0,
                "DrawIconEx failed"
            );
            GdiFlush();
            Ok(slice::from_raw_parts(bits.cast::<u8>(), len).to_vec())
        };
        let result = (|| {
            let mut black = render(0)?;
            let white = render(255)?;
            recover_alpha_from_black_white(&mut black, &white);
            Ok(black)
        })();
        SelectObject(dc, old);
        DeleteObject(bmp);
        DeleteDC(dc);
        result
    }
}

pub(super) fn png(data: &[u8], w: u32, h: u32) -> Result<Vec<u8>> {
    let mut result = Vec::new();
    let mut encoder = png::Encoder::new(&mut result, w, h);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.write_header()?.write_image_data(data)?;
    Ok(result)
}
pub(super) fn icon_to_png(icon: HICON) -> Option<Vec<u8>> {
    if icon.is_null() {
        return None;
    }
    png(&rgba(icon, 32, 32).ok()?, 32, 32).ok()
}
pub(super) fn app_icon(hwnd: HWND) -> Option<Vec<u8>> {
    unsafe {
        let mut icon = GetClassLongPtrW(hwnd, GCLP_HICON);
        if icon == 0 {
            SendMessageTimeoutW(
                hwnd,
                WM_GETICON,
                ICON_BIG as usize,
                0,
                SMTO_ABORTIFHUNG,
                50,
                &mut icon,
            );
        }
        if icon == 0 {
            icon = GetClassLongPtrW(hwnd, GCLP_HICONSM);
        }
        if icon == 0 {
            return None;
        }
        png(&rgba(icon as HICON, 32, 32).ok()?, 32, 32).ok()
    }
}
pub(super) fn cursor_pixels(icon: HICON) -> Option<(Vec<u8>, u32, u32, u32, u32)> {
    struct CursorResources {
        copied: HICON,
        info: ICONINFO,
    }
    impl Drop for CursorResources {
        fn drop(&mut self) {
            unsafe {
                if !self.info.hbmColor.is_null() {
                    DeleteObject(self.info.hbmColor);
                }
                if !self.info.hbmMask.is_null() {
                    DeleteObject(self.info.hbmMask);
                }
                if !self.copied.is_null() {
                    DestroyIcon(self.copied);
                }
            }
        }
    }

    unsafe {
        if icon.is_null() {
            return None;
        }
        let mut res = CursorResources {
            copied: ptr::null_mut(),
            info: mem::zeroed(),
        };
        let mut effective_icon = icon;
        if GetIconInfo(effective_icon, &mut res.info) == 0 {
            let copy = CopyIcon(icon);
            if copy.is_null() {
                return None;
            }
            res.copied = copy;
            effective_icon = copy;
            if GetIconInfo(effective_icon, &mut res.info) == 0 {
                return None;
            }
        }
        let mut bmp: BITMAP = mem::zeroed();
        let has_color = !res.info.hbmColor.is_null();
        let handle = if has_color {
            res.info.hbmColor
        } else {
            res.info.hbmMask
        };
        if handle.is_null()
            || GetObjectW(
                handle,
                mem::size_of::<BITMAP>() as i32,
                (&mut bmp as *mut BITMAP).cast(),
            ) == 0
        {
            return None;
        }
        let w = bmp.bmWidth.unsigned_abs();
        let raw_h = bmp.bmHeight.unsigned_abs();
        let h = if has_color { raw_h } else { raw_h / 2 };
        if w == 0 || h == 0 || w > 1024 || h > 1024 {
            return None;
        }
        let hx = res.info.xHotspot;
        let hy = res.info.yHotspot;

        // Oversized custom cursors (>256px) are downscaled via DrawIconEx so macOS always renders them.
        if w > 256 || h > 256 {
            let (sw, sh, shx, shy) = scaled_cursor_dimensions(w, h, hx, hy, 64);
            let pixels = rgba(effective_icon, sw, sh).ok()?;
            return Some((pixels, sw, sh, shx, shy));
        }

        // Primary extraction: read hbmColor / hbmMask directly via GetDIBits (immune to DrawIconEx
        // cross-process / 32-bit ARGB mask-blanking quirks seen in Unity & DirectX custom cursors).
        let dib_rgba = {
            let dc = CreateCompatibleDC(ptr::null_mut());
            let extracted = if dc.is_null() {
                None
            } else if has_color {
                read_dib_bgra(dc, res.info.hbmColor, w, h).map(|color| {
                    let has_alpha = color.chunks_exact(4).any(|px| px[3] != 0);
                    let mask = if !has_alpha && !res.info.hbmMask.is_null() {
                        read_dib_bgra(dc, res.info.hbmMask, w, h)
                    } else {
                        None
                    };
                    decode_color_cursor_bgra(&color, mask.as_deref())
                })
            } else {
                read_dib_bgra(dc, res.info.hbmMask, w, h.saturating_mul(2))
                    .and_then(|mask| decode_monochrome_cursor_mask(&mask, w, h))
            };
            if !dc.is_null() {
                DeleteDC(dc);
            }
            extracted
        };

        if let Some(pixels) = dib_rgba {
            if has_visible_pixel(&pixels) {
                return Some((pixels, w, h, hx, hy));
            }
            // Second opinion via DrawIconEx in case an animated/special cursor leaves GetDIBits blank;
            // genuinely transparent 3D-camera cursors stay all-transparent under both paths.
            if let Ok(drawn) = rgba(effective_icon, w, h) {
                if has_visible_pixel(&drawn) {
                    return Some((drawn, w, h, hx, hy));
                }
            }
            return Some((pixels, w, h, hx, hy));
        }

        Some((rgba(effective_icon, w, h).ok()?, w, h, hx, hy))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_32bit_argb_unity_cursor_preserves_alpha_and_swaps_bgra_to_rgba() {
        // BGRA pixels: opaque red, semi-transparent blue, fully transparent.
        let bgra = vec![
            0, 0, 255, 255, // red
            255, 64, 0, 128, // semi-transparent blue-teal
            0, 0, 0, 0, // transparent
        ];
        // Even if mask is all-ones (0xFF), 32-bit alpha channel must take precedence.
        let all_white_mask = vec![255u8; bgra.len()];
        let rgba = decode_color_cursor_bgra(&bgra, Some(&all_white_mask));
        assert_eq!(
            rgba,
            vec![
                255, 0, 0, 255, // red RGBA
                0, 64, 255, 128, // blue-teal RGBA
                0, 0, 0, 0, // transparent
            ]
        );
    }

    #[test]
    fn decode_legacy_color_cursor_uses_mask_when_alpha_is_all_zero() {
        // BGRA with alpha=0 (legacy 24/32bpp color cursor):
        // px0: opaque green (mask=0)
        // px1: transparent background (mask=255, color=black)
        // px2: XOR red highlight (mask=255, color=red)
        let bgra = vec![
            0, 200, 0, 0, // green
            0, 0, 0, 0, // black
            0, 0, 220, 0, // red
        ];
        let mask = vec![
            0, 0, 0, 0, // opaque
            255, 255, 255, 0, // transparent
            255, 255, 255, 0, // XOR
        ];
        let rgba = decode_color_cursor_bgra(&bgra, Some(&mask));
        assert_eq!(
            rgba,
            vec![
                0, 200, 0, 255, // opaque green
                0, 0, 0, 0, // transparent
                220, 0, 0, 255, // visible XOR red
            ]
        );
    }

    #[test]
    fn decode_monochrome_cursor_handles_and_xor_planes() {
        // 2x1 cursor -> 2x2 mask (top row AND, bottom row XOR).
        // px0: AND=0, XOR=0 -> opaque black
        // px1: AND=1, XOR=0 -> transparent
        // Let's test all 4 combinations in a 4x1 cursor!
        let mask = vec![
            // AND row (4 pixels)
            0, 0, 0, 0, // 0
            0, 0, 0, 0, // 0
            255, 255, 255, 0, // 1
            255, 255, 255, 0, // 1
            // XOR row (4 pixels)
            0, 0, 0, 0, // 0
            255, 255, 255, 0, // 1
            0, 0, 0, 0, // 0
            255, 255, 255, 0, // 1
        ];
        let rgba = decode_monochrome_cursor_mask(&mask, 4, 1).unwrap();
        assert_eq!(
            rgba,
            vec![
                0, 0, 0, 255, // black
                255, 255, 255, 255, // white
                0, 0, 0, 0, // transparent
                255, 255, 255, 255, // inverted XOR -> visible white
            ]
        );
    }

    #[test]
    fn black_white_alpha_recovery_checks_all_rgb_channels() {
        // Simulate a pure-red XOR pixel where B=0 on black and B=255 on white,
        // while R=255 on black and R=0 on white (single-channel blue check previously gave alpha=0!).
        let mut black = vec![
            0, 0, 255, 0, // BGRA pure red on black
            0, 0, 0, 0, // transparent pixel on black
        ];
        let white = vec![
            255, 255, 0, 255, // BGRA inverted on white
            255, 255, 255, 255, // transparent pixel stays white
        ];
        recover_alpha_from_black_white(&mut black, &white);
        assert_eq!(black[0..4], [255, 0, 0, 255]);
        assert_eq!(black[4..8], [0, 0, 0, 0]);
    }

    #[test]
    fn scaled_cursor_dimensions_clamps_oversized_cursors_and_hotspot() {
        assert_eq!(scaled_cursor_dimensions(64, 64, 8, 12, 64), (64, 64, 8, 12));
        assert_eq!(
            scaled_cursor_dimensions(512, 256, 64, 32, 64),
            (64, 32, 8, 4)
        );
    }
}
