import AppKit
import CoreGraphics
import Foundation

enum CursorMapper {
    private static let hiddenCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    /// Counts pixels with non-zero alpha in a custom cursor payload.
    static func visiblePixelCount(_ shape: CursorShape) -> Int {
        guard shape.cursorType == .custom else { return 0 }
        let bytes = [UInt8](shape.customRgba)
        guard bytes.count >= 4 else { return 0 }
        var count = 0
        var i = 3
        while i < bytes.count {
            if bytes[i] != 0 {
                count += 1
            }
            i += 4
        }
        return count
    }

    /// Computes Retina-safe logical point dimensions and clamped hotspot for a custom cursor.
    /// Caps logical dimensions at 64pt so oversized 4K Windows game cursors never exceed
    /// macOS WindowServer cursor sprite limits while staying sharp at 2x on Retina displays.
    static func logicalLayout(
        pixelWidth: Int,
        pixelHeight: Int,
        hotspotX: UInt32,
        hotspotY: UInt32
    ) -> (size: NSSize, hotSpot: NSPoint) {
        let maxDim = max(pixelWidth, pixelHeight)
        let scale: CGFloat
        if maxDim >= 48 {
            scale = max(2.0, CGFloat(maxDim) / 64.0)
        } else {
            scale = 1.0
        }
        let logicalW = max(1.0, (CGFloat(pixelWidth) / scale).rounded())
        let logicalH = max(1.0, (CGFloat(pixelHeight) / scale).rounded())
        let size = NSSize(width: logicalW, height: logicalH)
        let hotX = min(max(0.0, logicalW - 1.0), max(0.0, (CGFloat(hotspotX) / scale).rounded()))
        let hotY = min(max(0.0, logicalH - 1.0), max(0.0, (CGFloat(hotspotY) / scale).rounded()))
        return (size, NSPoint(x: hotX, y: hotY))
    }

    /// Returns true when Windows has hidden the cursor (or set an all-transparent custom cursor),
    /// which 3D games do during camera rotation and clear when showing menus or holding Alt.
    static func isEffectivelyHidden(_ shape: CursorShape) -> Bool {
        if shape.cursorType == .hidden {
            return true
        }
        if shape.cursorType == .custom {
            guard shape.customRgba.count >= 4 else { return false }
            return visiblePixelCount(shape) == 0
        }
        return false
    }

    /// Pure cursor-type resolution so force-visible fallback is deterministic and unit-testable
    /// without touching WindowServer/AppKit `NSCursor`.
    static func resolvedCursorType(for shape: CursorShape, forceVisible: Bool = false) -> CursorType {
        if forceVisible && isEffectivelyHidden(shape) {
            return .arrow
        }
        return shape.cursorType
    }

    static func cursor(from shape: CursorShape, forceVisible: Bool = false) -> NSCursor {
        switch resolvedCursorType(for: shape, forceVisible: forceVisible) {
        case .unspecified, .arrow:
            return .arrow
        case .ibeam:
            return .iBeam
        case .hand:
            return .pointingHand
        case .crosshair:
            return .crosshair
        case .wait, .appStarting:
            return .arrow
        case .sizeNS:
            return .resizeUpDown
        case .sizeWE:
            return .resizeLeftRight
        case .sizeNWSE, .sizeNESW:
            // Standard NSCursor lacks public diagonal arrows; fall back cleanly to crosshair/openHand or arrow.
            return .crosshair
        case .sizeAll:
            return .openHand
        case .no:
            return .operationNotAllowed
        case .hidden:
            return hiddenCursor
        case .custom:
            if let custom = buildCustomCursor(shape) {
                return custom
            }
            return .arrow
        }
    }

    static func buildCustomCursorImage(_ shape: CursorShape) -> (image: NSImage, hotSpot: NSPoint)? {
        let w = Int(shape.width)
        let h = Int(shape.height)
        guard w > 0, h > 0, w <= 256, h <= 256 else { return nil }
        let expectedBytes = w * h * 4
        guard shape.customRgba.count >= expectedBytes else { return nil }

        // Build a native AppKit premultiplied RGBA NSBitmapImageRep with explicit logical point
        // size so macOS WindowServer / SkyLight always renders custom game cursors crisply on Retina.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: w * 4,
            bitsPerPixel: 32
        ), let dst = rep.bitmapData else {
            return nil
        }

        shape.customRgba.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < expectedBytes {
                let r = Int(src[i])
                let g = Int(src[i + 1])
                let b = Int(src[i + 2])
                let a = Int(src[i + 3])
                if a == 255 {
                    dst[i] = UInt8(r)
                    dst[i + 1] = UInt8(g)
                    dst[i + 2] = UInt8(b)
                    dst[i + 3] = 255
                } else if a == 0 {
                    dst[i] = 0
                    dst[i + 1] = 0
                    dst[i + 2] = 0
                    dst[i + 3] = 0
                } else {
                    dst[i] = UInt8((r * a + 127) / 255)
                    dst[i + 1] = UInt8((g * a + 127) / 255)
                    dst[i + 2] = UInt8((b * a + 127) / 255)
                    dst[i + 3] = UInt8(a)
                }
                i += 4
            }
        }

        let layout = logicalLayout(
            pixelWidth: w,
            pixelHeight: h,
            hotspotX: shape.hotspotX,
            hotspotY: shape.hotspotY
        )
        rep.size = layout.size
        let image = NSImage(size: layout.size)
        image.addRepresentation(rep)
        return (image, layout.hotSpot)
    }

    static func buildCustomCursor(_ shape: CursorShape) -> NSCursor? {
        guard let built = buildCustomCursorImage(shape) else { return nil }
        return NSCursor(image: built.image, hotSpot: built.hotSpot)
    }
}
