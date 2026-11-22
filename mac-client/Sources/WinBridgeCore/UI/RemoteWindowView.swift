import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

enum GameLockState: Equatable {
    /// Normal macOS window behavior: free cursor, absolute coordinates.
    case off
    /// Game Lock armed while the Windows game is showing a cursor (e.g. holding Alt or menu open):
    /// visible game cursor confined inside the Mac window, pixel-accurate absolute coordinates.
    case confinedVisible
    /// Game Lock armed while the Windows game hides the cursor (3D camera / combat):
    /// hidden disassociated cursor at window center, sending raw relative dx/dy deltas.
    case relativeLocked
}

/// Pure integer-snapped confinement math with hysteresis so fractional Retina/aspect-ratio
/// video rects can NEVER cause a `CGWarpMouseCursorPosition` rounding self-warp freeze loop.
struct CursorConfinementBounds: Equatable, Sendable {
    let triggerRect: NSRect
    let warpTargetRect: NSRect

    init?(videoScreenRect: NSRect) {
        let trigMinX = ceil(videoScreenRect.minX) + 1
        let trigMaxX = floor(videoScreenRect.maxX) - 1
        let trigMinY = ceil(videoScreenRect.minY) + 1
        let trigMaxY = floor(videoScreenRect.maxY) - 1
        guard trigMaxX - trigMinX >= 4, trigMaxY - trigMinY >= 4 else { return nil }
        self.triggerRect = NSRect(
            x: trigMinX,
            y: trigMinY,
            width: trigMaxX - trigMinX,
            height: trigMaxY - trigMinY
        )
        let padX = min(3.0, floor((trigMaxX - trigMinX) * 0.25))
        let padY = min(3.0, floor((trigMaxY - trigMinY) * 0.25))
        let dstMinX = trigMinX + padX
        let dstMaxX = trigMaxX - padX
        let dstMinY = trigMinY + padY
        let dstMaxY = trigMaxY - padY
        self.warpTargetRect = NSRect(
            x: dstMinX,
            y: dstMinY,
            width: max(0, dstMaxX - dstMinX),
            height: max(0, dstMaxY - dstMinY)
        )
    }

    /// Returns a clamped integer Cocoa point strictly inside `warpTargetRect` if `point` escaped
    /// `triggerRect`, or `nil` if `point` is already safely inside (needing zero warps).
    func clampedWarpPoint(for point: NSPoint) -> NSPoint? {
        let escapedX = point.x < triggerRect.minX || point.x > triggerRect.maxX
        let escapedY = point.y < triggerRect.minY || point.y > triggerRect.maxY
        guard escapedX || escapedY else { return nil }
        let x = min(max(point.x.rounded(), warpTargetRect.minX), warpTargetRect.maxX)
        let y = min(max(point.y.rounded(), warpTargetRect.minY), warpTargetRect.maxY)
        return NSPoint(x: x, y: y)
    }
}

enum TransferToastStyle: Equatable {
    case progress
    case success
    case error
}

/// Renders decoded video frames via CoreAnimation/IOSurface and forwards mouse,
/// trackpad scroll, physical HID keyboard, and native macOS IME (`NSTextInputClient`) input.
@MainActor
final class RemoteWindowView: NSView, @preconcurrency NSTextInputClient {
    let windowId: UInt64
    var cmdMapsToCtrl: () -> Bool = { true }
    var mouseSensitivity: () -> Float = { 1.0 }
    var suppressInactiveHover: () -> Bool = { false }
    var shortcuts: () -> ShortcutBindings = { .defaults }
    var onSendControl: ((ControlMessage.Payload) -> Void)?
    var onRequestQuit: (() -> Void)?
    var onOpenManager: (() -> Void)?
    var onToggleHud: (() -> Void)?
    var onTogglePinOnTop: (() -> Void)?
    var onToggleMuteWindow: (() -> Void)?
    var onPullClipboardFiles: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    var onGameLockStateChanged: ((GameLockState) -> Void)?

    private(set) var gameLockEnabled = false
    private(set) var gameLockState: GameLockState = .off
    private(set) var alwaysShowLocalCursor = false
    private var remoteCursorHidden = false
    private var isCursorHidden = false
    private var pointerLockedAt: Date?
    private var gameLockEventMonitor: Any?
    private var lastCursorShape: CursorShape?
    private var lastLoggedCursorSummary: String?

    private let videoLayer = CALayer()
    private let hudContainer = NSView()
    private let hudLabel = NSTextField(labelWithString: "")
    private let dropOverlay = NSView()
    private let dropBadge = NSView()
    private let dropLabel = NSTextField(labelWithString: "")
    private let toastContainer = NSView()
    private let toastLabel = NSTextField(wrappingLabelWithString: "")
    private var toastHideTask: Task<Void, Never>?
    private var retainedFrame: DecodedImage?
    private var sourceSize: CGSize = .zero
    private var preserveAspectRatio: Bool = true
    private var trackingArea: NSTrackingArea?
    private var activeCursor: NSCursor = .arrow
    private var mouseInside = false
    private var pinchAccumulator: Double = 0.0

    // Keyboard & IME state
    private var markedText = NSMutableAttributedString()
    private var markedRangeStorage = NSRange(location: NSNotFound, length: 0)
    private var selectedRangeStorage = NSRange(location: 0, length: 0)
    private var lastMouseViewPoint = NSPoint(x: 40, y: 40)

    /// Tracks active physical keydowns so matching keyUps and focus-loss releases are always sent.
    private var heldKeyCodes: [UInt16: UInt32] = [:]
    private var heldModifiers: Set<UInt32> = []

    /// State shared across a single `interpretKeyEvents` call.
    private var currentKeyEvent: NSEvent?
    private var imeHandledCurrentKey = false
    private var hadMarkedTextBeforeKeyDown = false

    init(windowId: UInt64, frame: NSRect) {
        self.windowId = windowId
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.contentsGravity = .resize
        videoLayer.magnificationFilter = .linear
        videoLayer.minificationFilter = .linear
        videoLayer.isOpaque = false
        layer?.addSublayer(videoLayer)

        setupHudOverlay()
        setupDropAndToastOverlays()
        registerForDraggedTypes([.fileURL])
    }

    private func setupHudOverlay() {
        hudContainer.wantsLayer = true
        hudContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.72).cgColor
        hudContainer.layer?.cornerRadius = 6
        hudContainer.layer?.borderWidth = 0.5
        hudContainer.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor
        hudContainer.translatesAutoresizingMaskIntoConstraints = false
        hudContainer.isHidden = true

        hudLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        hudLabel.textColor = NSColor(calibratedRed: 0.62, green: 0.98, blue: 0.72, alpha: 1.0)
        hudLabel.translatesAutoresizingMaskIntoConstraints = false

        hudContainer.addSubview(hudLabel)
        addSubview(hudContainer)
        NSLayoutConstraint.activate([
            hudLabel.leadingAnchor.constraint(equalTo: hudContainer.leadingAnchor, constant: 8),
            hudLabel.trailingAnchor.constraint(equalTo: hudContainer.trailingAnchor, constant: -8),
            hudLabel.topAnchor.constraint(equalTo: hudContainer.topAnchor, constant: 4),
            hudLabel.bottomAnchor.constraint(equalTo: hudContainer.bottomAnchor, constant: -4),
            hudContainer.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            hudContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    private func setupDropAndToastOverlays() {
        // Drop highlight overlay sits above videoLayer so drag feedback is always visible.
        dropOverlay.wantsLayer = true
        dropOverlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        dropOverlay.layer?.borderWidth = 3
        dropOverlay.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.isHidden = true

        dropBadge.wantsLayer = true
        dropBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.86).cgColor
        dropBadge.layer?.cornerRadius = 10
        dropBadge.layer?.borderWidth = 1
        dropBadge.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        dropBadge.translatesAutoresizingMaskIntoConstraints = false

        dropLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        dropLabel.textColor = .white
        dropLabel.alignment = .center
        dropLabel.translatesAutoresizingMaskIntoConstraints = false

        dropBadge.addSubview(dropLabel)
        dropOverlay.addSubview(dropBadge)
        addSubview(dropOverlay)

        // Bottom-center transfer progress / result toast (click-through, sits above videoLayer).
        toastContainer.wantsLayer = true
        toastContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.86).cgColor
        toastContainer.layer?.cornerRadius = 8
        toastContainer.layer?.borderWidth = 1
        toastContainer.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.22).cgColor
        toastContainer.translatesAutoresizingMaskIntoConstraints = false
        toastContainer.isHidden = true

        toastLabel.font = .systemFont(ofSize: 12, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.alignment = .center
        toastLabel.maximumNumberOfLines = 3
        toastLabel.lineBreakMode = .byTruncatingMiddle
        toastLabel.translatesAutoresizingMaskIntoConstraints = false

        toastContainer.addSubview(toastLabel)
        addSubview(toastContainer)

        NSLayoutConstraint.activate([
            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropOverlay.topAnchor.constraint(equalTo: topAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            dropBadge.centerXAnchor.constraint(equalTo: dropOverlay.centerXAnchor),
            dropBadge.centerYAnchor.constraint(equalTo: dropOverlay.centerYAnchor),
            dropLabel.leadingAnchor.constraint(equalTo: dropBadge.leadingAnchor, constant: 18),
            dropLabel.trailingAnchor.constraint(equalTo: dropBadge.trailingAnchor, constant: -18),
            dropLabel.topAnchor.constraint(equalTo: dropBadge.topAnchor, constant: 10),
            dropLabel.bottomAnchor.constraint(equalTo: dropBadge.bottomAnchor, constant: -10),

            toastContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            toastContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            toastContainer.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            toastLabel.leadingAnchor.constraint(equalTo: toastContainer.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastContainer.trailingAnchor, constant: -14),
            toastLabel.topAnchor.constraint(equalTo: toastContainer.topAnchor, constant: 8),
            toastLabel.bottomAnchor.constraint(equalTo: toastContainer.bottomAnchor, constant: -8),
        ])
    }

    func showToast(_ text: String, style: TransferToastStyle, autoHideSeconds: TimeInterval?) {
        toastHideTask?.cancel()
        toastHideTask = nil
        toastLabel.stringValue = text
        switch style {
        case .progress:
            toastContainer.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
            toastLabel.textColor = .white
        case .success:
            toastContainer.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
            toastLabel.textColor = NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.84, alpha: 1.0)
        case .error:
            toastContainer.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
            toastLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.76, alpha: 1.0)
        }
        toastContainer.isHidden = false
        if let delay = autoHideSeconds, delay > 0 {
            toastHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.toastContainer.isHidden = true
            }
        }
    }

    func setHudVisible(_ visible: Bool) {
        hudContainer.isHidden = !visible
    }

    func updateHudText(_ text: String) {
        hudLabel.stringValue = text
    }

    // Ensure HUD badge is strictly click-through and never steals mouse events from the remote app.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    static func computeVideoRect(in bounds: NSRect, sourceSize: CGSize, preserveAspect: Bool) -> NSRect {
        guard preserveAspect, sourceSize.width > 0, sourceSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let w = sourceSize.width * scale
        let h = sourceSize.height * scale
        let x = (bounds.width - w) * 0.5
        let y = (bounds.height - h) * 0.5
        return NSRect(x: x, y: y, width: w, height: h)
    }

    var currentVideoRect: NSRect {
        Self.computeVideoRect(in: bounds, sourceSize: sourceSize, preserveAspect: preserveAspectRatio)
    }

    func updateDisplayGeometry(sourceSize: CGSize, preserveAspect: Bool) {
        self.sourceSize = sourceSize
        self.preserveAspectRatio = preserveAspect
        layoutVideoLayer()
    }

    private func layoutVideoLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = currentVideoRect
        if let scale = window?.backingScaleFactor {
            videoLayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Top-left origin matches Windows coordinate space directly.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            setGameLockEnabled(false)
            removeGameLockEventMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        layoutVideoLayer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Frame & Cursor Updates

    func display(frame: DecodedImage) {
        retainedFrame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = frame.layerContents
        CATransaction.commit()
    }

    func setAlwaysShowLocalCursor(_ enabled: Bool) {
        guard enabled != alwaysShowLocalCursor else { return }
        alwaysShowLocalCursor = enabled
        ClientLogger.shared.info(
            "AlwaysShowLocalCursor \(enabled ? "ENABLED" : "DISABLED") for window 0x\(String(windowId, radix: 16))"
        )
        if let lastCursorShape {
            activeCursor = CursorMapper.cursor(
                from: lastCursorShape,
                forceVisible: enabled && gameLockState != .relativeLocked
            )
        } else if enabled {
            activeCursor = .arrow
        }
        if mouseInside && gameLockState != .relativeLocked {
            activeCursor.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    func applyCursorShape(_ shape: CursorShape) {
        lastCursorShape = shape
        let hidden = CursorMapper.isEffectivelyHidden(shape)
        let summary: String
        if shape.cursorType == .custom {
            let visible = CursorMapper.visiblePixelCount(shape)
            summary = "custom \(shape.width)x\(shape.height) hotspot=(\(shape.hotspotX),\(shape.hotspotY)) visiblePx=\(visible)"
        } else {
            summary = "\(shape.cursorType)"
        }
        if summary != lastLoggedCursorSummary {
            lastLoggedCursorSummary = summary
            ClientLogger.shared.info("Cursor 0x\(String(windowId, radix: 16)) -> \(summary)")
        }

        if hidden != remoteCursorHidden {
            remoteCursorHidden = hidden
            if gameLockEnabled {
                ClientLogger.shared.info(
                    "GameLock cursor -> \(hidden ? "hidden (3D relative)" : "visible (menu pointer)") type=\(shape.cursorType)"
                )
            }
            reconcileGameLockState()
        }
        let cursor = CursorMapper.cursor(
            from: shape,
            forceVisible: alwaysShowLocalCursor && gameLockState != .relativeLocked
        )
        activeCursor = cursor
        if mouseInside && gameLockState != .relativeLocked {
            cursor.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func cursorUpdate(with event: NSEvent) {
        if gameLockState != .relativeLocked {
            activeCursor.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: activeCursor)
    }

    // MARK: - Smart 3D Game Mouse Lock (Auto-switches between 3D Relative & Confined Menu Pointer)

    func setGameLockEnabled(_ enabled: Bool) {
        guard enabled != gameLockEnabled else { return }
        gameLockEnabled = enabled
        ClientLogger.shared.info(
            "GameLock \(enabled ? "ENABLED" : "DISABLED") for window 0x\(String(windowId, radix: 16)) (remoteCursorHidden=\(remoteCursorHidden))"
        )
        reconcileGameLockState()
    }

    private func cocoaToCGPoint(_ cocoaScreenPoint: NSPoint) -> CGPoint {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: cocoaScreenPoint.x, y: primaryHeight - cocoaScreenPoint.y)
    }

    /// Warps the macOS cursor without triggering macOS's default 250ms local hardware input
    /// suppression interval (`CGEventSource.localEventsSuppressionInterval`).
    private func warpCursorWithoutSuppression(toCocoaPoint point: NSPoint, keepAssociated: Bool) {
        if let src = CGEventSource(stateID: .combinedSessionState) {
            src.localEventsSuppressionInterval = 0.0
        }
        let cgPt = cocoaToCGPoint(NSPoint(x: point.x.rounded(), y: point.y.rounded()))
        CGWarpMouseCursorPosition(cgPt)
        CGAssociateMouseAndMouseCursorPosition(keepAssociated ? 1 : 0)
    }

    private func videoRectInCocoaScreen() -> NSRect? {
        guard let window else { return nil }
        let rectInWin = convert(currentVideoRect, to: nil)
        return window.convertToScreen(rectInWin)
    }

    private func warpCursorToVideoCenter(keepAssociated: Bool) {
        guard let screenRect = videoRectInCocoaScreen() else { return }
        let center = NSPoint(x: screenRect.midX.rounded(), y: screenRect.midY.rounded())
        warpCursorWithoutSuppression(toCocoaPoint: center, keepAssociated: keepAssociated)
    }

    @discardableResult
    private func confineCursorIfNeeded() -> NSPoint? {
        guard gameLockState == .confinedVisible,
              let screenRect = videoRectInCocoaScreen(),
              let confinement = CursorConfinementBounds(videoScreenRect: screenRect) else { return nil }
        let pos = NSEvent.mouseLocation
        guard let warped = confinement.clampedWarpPoint(for: pos) else { return nil }
        warpCursorWithoutSuppression(toCocoaPoint: warped, keepAssociated: true)
        return warped
    }

    private func normalizedPoint(fromCocoaScreenPoint screenPoint: NSPoint) -> (Float, Float) {
        guard let window else { return (0.5, 0.5) }
        let winPt = window.convertPoint(fromScreen: screenPoint)
        let local = convert(winPt, from: nil)
        lastMouseViewPoint = local
        let rect = currentVideoRect
        let w = max(rect.width, 1.0)
        let h = max(rect.height, 1.0)
        let nx = min(max(Float((local.x - rect.minX) / w), 0.0), 1.0)
        let ny = min(max(Float((local.y - rect.minY) / h), 0.0), 1.0)
        return (nx, ny)
    }

    private func installGameLockEventMonitorIfNeeded() {
        guard gameLockEventMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel,
        ]
        gameLockEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handleGameLockLocalEvent(event)
        }
    }

    private func removeGameLockEventMonitor() {
        if let monitor = gameLockEventMonitor {
            NSEvent.removeMonitor(monitor)
            gameLockEventMonitor = nil
        }
    }

    /// Window-wide mouse interceptor active only while Game Lock is enabled on the key window.
    /// Prevents the macOS top title bar (`NSThemeFrame`) from stealing mouse tracking, freezing
    /// `relativeLocked` deltas, or accidentally starting native window drags during gameplay.
    private func handleGameLockLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard gameLockEnabled,
              let window,
              window.isKeyWindow,
              NSApp.isActive else {
            return event
        }
        if event.type == .flagsChanged {
            if event.modifierFlags.contains([.control, .option]) {
                setGameLockEnabled(false)
                releaseAllHeldKeys()
                return nil
            }
            return event
        }

        switch gameLockState {
        case .off:
            return event

        case .relativeLocked:
            switch event.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                sendRelativeMove(event: event)
                return nil
            case .leftMouseDown:
                window.makeFirstResponder(self)
                sendMouse(event: event, kind: .buttonDown, button: .left)
                return nil
            case .leftMouseUp:
                sendMouse(event: event, kind: .buttonUp, button: .left)
                return nil
            case .rightMouseDown:
                window.makeFirstResponder(self)
                sendMouse(event: event, kind: .buttonDown, button: .right)
                return nil
            case .rightMouseUp:
                sendMouse(event: event, kind: .buttonUp, button: .right)
                return nil
            case .otherMouseDown:
                window.makeFirstResponder(self)
                sendMouse(event: event, kind: .buttonDown, button: mapOtherButton(event.buttonNumber))
                return nil
            case .otherMouseUp:
                sendMouse(event: event, kind: .buttonUp, button: mapOtherButton(event.buttonNumber))
                return nil
            case .scrollWheel:
                scrollWheel(with: event)
                return nil
            default:
                return event
            }

        case .confinedVisible:
            let warped = confineCursorIfNeeded()
            let eventInsideView: Bool
            if event.window === window {
                eventInsideView = bounds.contains(convert(event.locationInWindow, from: nil))
            } else {
                eventInsideView = false
            }

            guard warped != nil || !eventInsideView else {
                // Cursor and event are safely inside the video view; let standard NSView handlers run.
                return event
            }

            let targetPoint = warped ?? NSEvent.mouseLocation
            let (nx, ny) = normalizedPoint(fromCocoaScreenPoint: targetPoint)
            let mods = MacKeyToHID.modifierMask(from: event.modifierFlags, cmdMapsToCtrl: cmdMapsToCtrl())
            switch event.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                let btn: MouseButton
                switch event.type {
                case .leftMouseDragged: btn = .left
                case .rightMouseDragged: btn = .right
                case .otherMouseDragged: btn = mapOtherButton(event.buttonNumber)
                default: btn = .unspecified
                }
                onSendControl?(.mouseEvent(MouseEvent(
                    windowId: windowId,
                    kind: .move,
                    normX: nx,
                    normY: ny,
                    button: btn,
                    modifiers: mods
                )))
                return nil
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                window.makeFirstResponder(self)
                let btn: MouseButton = event.type == .leftMouseDown
                    ? .left
                    : (event.type == .rightMouseDown ? .right : mapOtherButton(event.buttonNumber))
                onSendControl?(.mouseEvent(MouseEvent(
                    windowId: windowId,
                    kind: .buttonDown,
                    normX: nx,
                    normY: ny,
                    button: btn,
                    modifiers: mods
                )))
                return nil
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                let btn: MouseButton = event.type == .leftMouseUp
                    ? .left
                    : (event.type == .rightMouseUp ? .right : mapOtherButton(event.buttonNumber))
                onSendControl?(.mouseEvent(MouseEvent(
                    windowId: windowId,
                    kind: .buttonUp,
                    normX: nx,
                    normY: ny,
                    button: btn,
                    modifiers: mods
                )))
                return nil
            case .scrollWheel:
                scrollWheel(with: event)
                return nil
            default:
                return event
            }
        }
    }

    private func reconcileGameLockState() {
        let desired: GameLockState
        if !gameLockEnabled {
            desired = .off
        } else if remoteCursorHidden {
            desired = .relativeLocked
        } else {
            desired = .confinedVisible
        }
        guard desired != gameLockState else { return }
        let previous = gameLockState
        gameLockState = desired

        switch desired {
        case .relativeLocked:
            guard let window else {
                gameLockState = .off
                gameLockEnabled = false
                removeGameLockEventMonitor()
                return
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self)
            if previous == .off {
                onSendControl?(.focusWindow(FocusWindow(windowId: windowId, focused: true)))
                onSendControl?(.mouseEvent(MouseEvent(
                    windowId: windowId,
                    kind: .move,
                    normX: 0.5,
                    normY: 0.5
                )))
            }
            installGameLockEventMonitorIfNeeded()
            warpCursorToVideoCenter(keepAssociated: false)
            if !isCursorHidden {
                NSCursor.hide()
                isCursorHidden = true
            }
            pointerLockedAt = Date()

        case .confinedVisible:
            pointerLockedAt = nil
            installGameLockEventMonitorIfNeeded()
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
            if previous == .relativeLocked {
                // Game just revealed cursor (Alt / menu open): show cursor right at window center
                // and align Windows cursor cleanly without 250ms warp suppression.
                warpCursorToVideoCenter(keepAssociated: true)
                onSendControl?(.mouseEvent(MouseEvent(
                    windowId: windowId,
                    kind: .move,
                    normX: 0.5,
                    normY: 0.5
                )))
            } else {
                CGAssociateMouseAndMouseCursorPosition(1)
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(self)
                confineCursorIfNeeded()
            }
            activeCursor.set()

        case .off:
            pointerLockedAt = nil
            removeGameLockEventMonitor()
            CGAssociateMouseAndMouseCursorPosition(1)
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
            if let lastCursorShape {
                activeCursor = CursorMapper.cursor(
                    from: lastCursorShape,
                    forceVisible: alwaysShowLocalCursor
                )
                window?.invalidateCursorRects(for: self)
            }
            if mouseInside {
                activeCursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        onGameLockStateChanged?(desired)
    }

    // MARK: - Focus & Stuck-Key Safety

    func releaseAllHeldKeys() {
        for (_, hid) in heldKeyCodes {
            sendKeyEvent(hid: hid, isDown: false, isRepeat: false, flags: [])
        }
        heldKeyCodes.removeAll()
        for hid in heldModifiers {
            sendKeyEvent(hid: hid, isDown: false, isRepeat: false, flags: [])
        }
        heldModifiers.removeAll()
        clearMarkedText()
    }

    // MARK: - Mouse & Trackpad

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        if gameLockState != .relativeLocked {
            activeCursor.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if gameLockState == .confinedVisible {
            confineCursorIfNeeded()
            return
        }
        mouseInside = false
        if gameLockState != .relativeLocked {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if gameLockState == .relativeLocked {
            sendRelativeMove(event: event)
        } else {
            if suppressInactiveHover() && window?.isKeyWindow != true {
                return
            }
            sendMouse(event: event, kind: .move, button: .unspecified)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if gameLockState == .relativeLocked {
            sendRelativeMove(event: event)
        } else {
            sendMouse(event: event, kind: .move, button: .left)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if gameLockState == .relativeLocked {
            sendRelativeMove(event: event)
        } else {
            sendMouse(event: event, kind: .move, button: .right)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if gameLockState == .relativeLocked {
            sendRelativeMove(event: event)
        } else {
            sendMouse(event: event, kind: .move, button: mapOtherButton(event.buttonNumber))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event: event, kind: .buttonDown, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(event: event, kind: .buttonUp, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event: event, kind: .buttonDown, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(event: event, kind: .buttonUp, button: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event: event, kind: .buttonDown, button: mapOtherButton(event.buttonNumber))
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(event: event, kind: .buttonUp, button: mapOtherButton(event.buttonNumber))
    }

    override func scrollWheel(with event: NSEvent) {
        let (nx, ny) = normalizedPoint(from: event)
        let wheelX: Float
        let wheelY: Float
        if event.hasPreciseScrollingDeltas {
            // Trackpad: ~40pt scroll ~= 120 WHEEL_DELTA.
            // macOS scrollingDeltaY > 0 already matches Windows WHEEL_DELTA > 0 (scroll up).
            // macOS scrollingDeltaX > 0 moves content right (scroll left), opposite of Windows HWHEEL > 0.
            let scale: Float = 3.0
            wheelY = Float(event.scrollingDeltaY) * scale
            wheelX = -Float(event.scrollingDeltaX) * scale
        } else {
            wheelY = Float(event.scrollingDeltaY) * 120.0
            wheelX = -Float(event.scrollingDeltaX) * 120.0
        }
        guard wheelX != 0 || wheelY != 0 else { return }
        let mods = MacKeyToHID.modifierMask(from: event.modifierFlags, cmdMapsToCtrl: cmdMapsToCtrl())
        onSendControl?(.mouseEvent(MouseEvent(
            windowId: windowId,
            kind: .wheel,
            normX: nx,
            normY: ny,
            button: .unspecified,
            wheelDeltaX: wheelX,
            wheelDeltaY: wheelY,
            modifiers: mods,
            isRelative: gameLockState == .relativeLocked
        )))
    }

    /// Maps macOS two-finger trackpad pinch-to-zoom to Windows Ctrl+MouseWheel at cursor position.
    override func magnify(with event: NSEvent) {
        if event.phase == .began {
            pinchAccumulator = 0
        }
        pinchAccumulator += Double(event.magnification)
        let threshold = 0.045
        if abs(pinchAccumulator) >= threshold {
            let steps = Int((pinchAccumulator / threshold).rounded(.towardZero))
            if steps != 0 {
                pinchAccumulator -= Double(steps) * threshold
                let (nx, ny) = normalizedPoint(from: event)
                let wheelY = Float(steps) * 120.0
                onSendControl?(.mouseEvent(MouseEvent(
                    windowId: windowId,
                    kind: .wheel,
                    normX: nx,
                    normY: ny,
                    button: .unspecified,
                    wheelDeltaX: 0,
                    wheelDeltaY: wheelY,
                    modifiers: KeyModifierMask.lCtrl.rawValue,
                    isRelative: gameLockState == .relativeLocked
                )))
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            pinchAccumulator = 0
        }
    }

    private func mapOtherButton(_ buttonNumber: Int) -> MouseButton {
        switch buttonNumber {
        case 2: return .middle
        case 3: return .x1
        case 4: return .x2
        default: return .middle
        }
    }

    private func normalizedPoint(from event: NSEvent) -> (Float, Float) {
        let local = convert(event.locationInWindow, from: nil)
        lastMouseViewPoint = local
        let rect = currentVideoRect
        let w = max(rect.width, 1.0)
        let h = max(rect.height, 1.0)
        var nx = Float((local.x - rect.minX) / w)
        var ny = Float((local.y - rect.minY) / h)
        if gameLockState == .confinedVisible {
            nx = min(max(nx, 0.0), 1.0)
            ny = min(max(ny, 0.0), 1.0)
        }
        return (nx, ny)
    }

    private func sendRelativeMove(event: NSEvent) {
        if let lockedAt = pointerLockedAt, Date().timeIntervalSince(lockedAt) < 0.035 {
            return
        }
        let sens = max(0.1, min(4.0, mouseSensitivity()))
        let dx = Float(event.deltaX) * sens
        let dy = Float(event.deltaY) * sens
        guard dx != 0 || dy != 0 else { return }
        let mods = MacKeyToHID.modifierMask(from: event.modifierFlags, cmdMapsToCtrl: cmdMapsToCtrl())
        onSendControl?(.mouseEvent(MouseEvent(
            windowId: windowId,
            kind: .relativeMove,
            modifiers: mods,
            deltaX: dx,
            deltaY: dy,
            isRelative: true
        )))
    }

    private func sendMouse(event: NSEvent, kind: MouseEventKind, button: MouseButton) {
        let mods = MacKeyToHID.modifierMask(from: event.modifierFlags, cmdMapsToCtrl: cmdMapsToCtrl())
        if gameLockState == .relativeLocked {
            onSendControl?(.mouseEvent(MouseEvent(
                windowId: windowId,
                kind: kind,
                button: button,
                modifiers: mods,
                isRelative: true
            )))
            return
        }
        let (nx, ny) = normalizedPoint(from: event)
        onSendControl?(.mouseEvent(MouseEvent(
            windowId: windowId,
            kind: kind,
            normX: nx,
            normY: ny,
            button: button,
            wheelDeltaX: 0,
            wheelDeltaY: 0,
            modifiers: mods
        )))
    }

    // MARK: - Keyboard & Shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let sc = shortcuts()
        if sc.toggleGameLock.matches(event: event) {
            setGameLockEnabled(!gameLockEnabled)
            return true
        }
        if sc.toggleHud.matches(event: event) {
            onToggleHud?()
            return true
        }
        if sc.pinOnTop.matches(event: event) {
            onTogglePinOnTop?()
            return true
        }
        if sc.muteWindow.matches(event: event) {
            onToggleMuteWindow?()
            return true
        }
        if sc.pullClipboardFiles.matches(event: event) {
            onPullClipboardFiles?()
            return true
        }
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        // Keep Cmd+Q (quit WinBridge) and Cmd+, (bring Manager to front) native on macOS.
        if flags == .command {
            if event.keyCode == UInt16(kVK_ANSI_Q) {
                setGameLockEnabled(false)
                releaseAllHeldKeys()
                onRequestQuit?()
                return true
            }
            if event.keyCode == UInt16(kVK_ANSI_Comma) {
                setGameLockEnabled(false)
                releaseAllHeldKeys()
                onOpenManager?()
                return true
            }
        }

        handlePhysicalKeyDown(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        if gameLockEnabled && event.modifierFlags.contains([.control, .option]) {
            setGameLockEnabled(false)
            releaseAllHeldKeys()
            return
        }
        syncModifiers(from: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        syncModifiers(from: event.modifierFlags)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShortcutMod = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)

        // Bypass IME for shortcuts or control keys when no Chinese/IME composition is in progress.
        if !hasMarkedText() && (hasShortcutMod || MacKeyToHID.isNonCharacterControlKey(event.keyCode)) {
            handlePhysicalKeyDown(event)
            return
        }

        currentKeyEvent = event
        imeHandledCurrentKey = false
        hadMarkedTextBeforeKeyDown = hasMarkedText()
        interpretKeyEvents([event])
        currentKeyEvent = nil

        // If IME didn't insert text or manage composition, fall back to raw HID key.
        if !imeHandledCurrentKey && !hadMarkedTextBeforeKeyDown && !hasMarkedText() {
            handlePhysicalKeyDown(event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let hid = heldKeyCodes.removeValue(forKey: event.keyCode) {
            sendKeyEvent(hid: hid, isDown: false, isRepeat: false, flags: event.modifierFlags)
        }
    }

    private func handlePhysicalKeyDown(_ event: NSEvent) {
        guard let hid = MacKeyToHID.hidUsage(for: event.keyCode) else { return }
        heldKeyCodes[event.keyCode] = hid
        sendKeyEvent(hid: hid, isDown: true, isRepeat: event.isARepeat, flags: event.modifierFlags)
    }

    private func syncModifiers(from flags: NSEvent.ModifierFlags) {
        let raw = flags.rawValue
        let mapCmd = cmdMapsToCtrl()
        var desired = Set<UInt32>()

        if flags.contains(.shift) {
            if (raw & UInt(NX_DEVICERSHIFTKEYMASK)) != 0 { desired.insert(MacKeyToHID.HID.rightShift) }
            if (raw & UInt(NX_DEVICELSHIFTKEYMASK)) != 0 || !desired.contains(MacKeyToHID.HID.rightShift) {
                desired.insert(MacKeyToHID.HID.leftShift)
            }
        }
        if flags.contains(.control) {
            if (raw & UInt(NX_DEVICERCTLKEYMASK)) != 0 { desired.insert(MacKeyToHID.HID.rightControl) }
            if (raw & UInt(NX_DEVICELCTLKEYMASK)) != 0 || !desired.contains(MacKeyToHID.HID.rightControl) {
                desired.insert(MacKeyToHID.HID.leftControl)
            }
        }
        if flags.contains(.option) {
            if (raw & UInt(NX_DEVICERALTKEYMASK)) != 0 { desired.insert(MacKeyToHID.HID.rightAlt) }
            if (raw & UInt(NX_DEVICELALTKEYMASK)) != 0 || !desired.contains(MacKeyToHID.HID.rightAlt) {
                desired.insert(MacKeyToHID.HID.leftAlt)
            }
        }
        if flags.contains(.command) {
            if mapCmd {
                desired.insert(MacKeyToHID.HID.leftControl)
            } else {
                if (raw & UInt(NX_DEVICERCMDKEYMASK)) != 0 { desired.insert(MacKeyToHID.HID.rightGui) }
                if (raw & UInt(NX_DEVICELCMDKEYMASK)) != 0 || !desired.contains(MacKeyToHID.HID.rightGui) {
                    desired.insert(MacKeyToHID.HID.leftGui)
                }
            }
        }

        // Release modifiers no longer held
        for released in heldModifiers.subtracting(desired) {
            sendKeyEvent(hid: released, isDown: false, isRepeat: false, flags: flags)
        }
        // Press newly held modifiers
        for pressed in desired.subtracting(heldModifiers) {
            sendKeyEvent(hid: pressed, isDown: true, isRepeat: false, flags: flags)
        }
        heldModifiers = desired
    }

    private func sendKeyEvent(hid: UInt32, isDown: Bool, isRepeat: Bool, flags: NSEvent.ModifierFlags) {
        let mask = MacKeyToHID.modifierMask(from: flags, cmdMapsToCtrl: cmdMapsToCtrl())
        onSendControl?(.keyEvent(KeyEvent(
            windowId: windowId,
            isDown: isDown,
            isRepeat: isRepeat,
            hidUsage: hid,
            modifiers: mask
        )))
    }

    // MARK: - NSTextInputClient (Native macOS Chinese / CJK IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attr = string as? NSAttributedString {
            text = attr.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        let wasComposing = hadMarkedTextBeforeKeyDown || hasMarkedText()
        clearMarkedText()
        imeHandledCurrentKey = true

        guard !text.isEmpty else { return }

        // For plain single ASCII keystrokes without IME composition, send the physical HID scancode
        // so terminals, editors, and games receive exact key down/up events.
        // For Chinese/CJK, emoji, multi-char commits, or IME punctuation, inject via KEYEVENTF_UNICODE.
        if !wasComposing,
           text.utf8.count == 1,
           let scalar = text.unicodeScalars.first,
           scalar.value >= 0x20 && scalar.value < 0x7F,
           let ev = currentKeyEvent,
           MacKeyToHID.hidUsage(for: ev.keyCode) != nil {
            handlePhysicalKeyDown(ev)
        } else {
            onSendControl?(.textInput(TextInput(windowId: windowId, text: text)))
        }
    }

    override func doCommand(by selector: Selector) {
        // Non-character editing commands (Enter, Backspace, Arrows, Escape):
        // If IME was actively composing, the IME already handled the key; otherwise forward raw HID key.
        if !hadMarkedTextBeforeKeyDown, let ev = currentKeyEvent {
            imeHandledCurrentKey = true
            handlePhysicalKeyDown(ev)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attr = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attr)
        } else if let str = string as? String {
            markedText = NSMutableAttributedString(string: str)
        } else {
            markedText = NSMutableAttributedString()
        }
        markedRangeStorage = markedText.length > 0
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
        selectedRangeStorage = selectedRange
        imeHandledCurrentKey = true
    }

    func unmarkText() {
        clearMarkedText()
    }

    func selectedRange() -> NSRange {
        selectedRangeStorage
    }

    func markedRange() -> NSRange {
        markedRangeStorage
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let clampedX = min(max(lastMouseViewPoint.x, 12), max(12, bounds.width - 12))
        let clampedY = min(max(lastMouseViewPoint.y, 12), max(12, bounds.height - 12))
        let viewRect = NSRect(x: clampedX, y: clampedY, width: 1, height: 18)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    private func clearMarkedText() {
        markedText = NSMutableAttributedString()
        markedRangeStorage = NSRange(location: NSNotFound, length: 0)
        selectedRangeStorage = NSRange(location: 0, length: 0)
    }

    // MARK: - Drag & Drop File Transfer (Mac -> Windows Downloads\WinBridge)

    private func inspectDroppedURLs(from info: NSDraggingInfo) -> (files: [URL], skippedDirs: Int) {
        guard let items = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return ([], 0)
        }
        var files: [URL] = []
        var skippedDirs = 0
        for raw in items {
            let resolved = raw.standardizedFileURL.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    skippedDirs += 1
                } else {
                    files.append(resolved)
                }
            }
        }
        return (files, skippedDirs)
    }

    private func updateDropOverlay(for info: NSDraggingInfo) -> NSDragOperation {
        let (files, skippedDirs) = inspectDroppedURLs(from: info)
        if !files.isEmpty {
            let countText = files.count == 1
                ? "松开鼠标发送「\(files[0].lastPathComponent)」到 Windows"
                : "松开鼠标发送 \(files.count) 个文件到 Windows"
            dropLabel.stringValue = skippedDirs > 0
                ? "\(countText)（将跳过 \(skippedDirs) 个文件夹）"
                : countText
            dropOverlay.isHidden = false
            return .copy
        }
        if skippedDirs > 0 {
            dropLabel.stringValue = "暂不支持直接拖放文件夹，请先压缩或拖入文件"
            dropOverlay.isHidden = false
            return .copy
        }
        dropOverlay.isHidden = true
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropOverlay(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropOverlay.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay.isHidden = true
        let (files, skippedDirs) = inspectDroppedURLs(from: sender)
        ClientLogger.shared.info(
            "FileDrop on window 0x\(String(windowId, radix: 16)): files=\(files.count) skippedDirs=\(skippedDirs)"
        )
        if files.isEmpty {
            if skippedDirs > 0 {
                showToast("暂不支持直接拖放文件夹，请先压缩为 zip 或拖入单个/多个文件", style: .error, autoHideSeconds: 4.5)
            }
            return false
        }
        if skippedDirs > 0 {
            showToast("已跳过 \(skippedDirs) 个文件夹，正在发送 \(files.count) 个文件…", style: .progress, autoHideSeconds: nil)
        }
        onFilesDropped?(files)
        return true
    }
}
