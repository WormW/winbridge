import AppKit
import Foundation

private final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum PerformanceHUDFormatter {
    static func format(
        codecName: String,
        fps: Double,
        mbps: Double,
        rttMs: Double?,
        width: UInt16,
        height: UInt16
    ) -> String {
        let rttStr = rttMs.map { String(format: "%.1fms", $0) } ?? "--"
        let dims = (width > 0 && height > 0) ? " · \(width)×\(height)" : ""
        return String(format: "%@ · %.0f FPS · %.1f Mbps · RTT %@%@", codecName, fps, mbps, rttStr, dims)
    }
}

@MainActor
final class RemoteWindowController: NSWindowController, NSWindowDelegate {
    let windowId: UInt64
    private(set) var info: WindowInfo
    let remoteView: RemoteWindowView
    let decoder: WindowVideoDecoder

    var onSendControl: ((ControlMessage.Payload) -> Void)?
    var onDetachRequested: ((UInt64) -> Void)?
    var onOwnerMovedOrResized: ((UInt64) -> Void)?
    var onRequestQuit: (() -> Void)?
    var onOpenManager: (() -> Void)?
    var onToggleHud: (() -> Void)?
    var onToggleMuteWindow: ((UInt64) -> Void)?
    var onPinOnTopChanged: (() -> Void)?
    var onLayoutChanged: ((UInt64) -> Void)?
    var onPullClipboardFiles: (() -> Void)?
    var onFilesDropped: ((UInt64, [URL]) -> Void)?
    var cmdMapsToCtrl: () -> Bool = { true }
    var syncWindowResize: () -> Bool = { false }
    var mouseSensitivity: () -> Float = { 1.0 }
    var suppressInactiveHover: () -> Bool = { false }
    var shortcuts: () -> ShortcutBindings = { .defaults }
    var currentRttMs: () -> Double? = { nil }
    var showPerformanceHud: () -> Bool = { false }

    private var baseTitle: String = ""
    private(set) var isPinnedOnTop = false
    private(set) var isAudioMuted = false
    private var isApplyingRemoteGeometry = false
    private var isLiveResizing = false
    private var localResizeSeq: UInt32 = 0
    private var lastResizeSentAt: Date?
    private var resizeDebounceTimer: Timer?
    private var layoutSaveTimer: Timer?
    private var lastCloseAttemptAt: Date?
    private var allowImmediateClose = false
    private var lastFrameSize: (UInt16, UInt16)?

    // Rolling Performance HUD counters
    private var hudTimer: Timer?
    private var hudWindowStart = Date()
    private var hudFramesInWindow: Int = 0
    private var hudBytesInWindow: Int = 0
    private var hudLastCodec: String = "—"

    init(info: WindowInfo, owner: RemoteWindowController?, syncWindowResize: @escaping () -> Bool) {
        self.windowId = info.windowId
        self.info = info
        self.syncWindowResize = syncWindowResize
        self.decoder = WindowVideoDecoder(windowId: info.windowId)

        let contentSize = Self.macContentSize(for: info)
        let contentRect = NSRect(origin: .zero, size: contentSize)
        self.remoteView = RemoteWindowView(windowId: info.windowId, frame: contentRect)

        let window: NSWindow
        switch info.kind {
        case .popup:
            let panel = PopupPanel(
                contentRect: contentRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.hasShadow = true
            panel.isOpaque = !info.hasAlpha
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = true
            panel.collectionBehavior = [.moveToActiveSpace, .transient]
            window = panel

        case .dialog:
            let win = NSWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = info.title.isEmpty ? info.processName : info.title
            win.isReleasedWhenClosed = false
            window = win

        case .normal, .unspecified:
            let win = NSWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = info.title.isEmpty ? info.processName : info.title
            win.isReleasedWhenClosed = false
            window = win
        }

        window.contentView = remoteView
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 160, height: 100)

        self.baseTitle = info.title.isEmpty ? info.processName : info.title
        super.init(window: window)
        window.delegate = self

        remoteView.cmdMapsToCtrl = { [weak self] in self?.cmdMapsToCtrl() ?? true }
        remoteView.mouseSensitivity = { [weak self] in self?.mouseSensitivity() ?? 1.0 }
        remoteView.suppressInactiveHover = { [weak self] in self?.suppressInactiveHover() ?? false }
        remoteView.shortcuts = { [weak self] in self?.shortcuts() ?? .defaults }
        remoteView.onSendControl = { [weak self] payload in self?.onSendControl?(payload) }
        remoteView.onRequestQuit = { [weak self] in self?.onRequestQuit?() }
        remoteView.onOpenManager = { [weak self] in self?.onOpenManager?() }
        remoteView.onToggleHud = { [weak self] in self?.onToggleHud?() }
        remoteView.onTogglePinOnTop = { [weak self] in self?.togglePinOnTop() }
        remoteView.onToggleMuteWindow = { [weak self] in
            guard let self else { return }
            self.onToggleMuteWindow?(self.windowId)
        }
        remoteView.onPullClipboardFiles = { [weak self] in self?.onPullClipboardFiles?() }
        remoteView.onFilesDropped = { [weak self] urls in
            guard let self else { return }
            self.onFilesDropped?(self.windowId, urls)
        }
        remoteView.onGameLockStateChanged = { [weak self] _ in self?.updateWindowTitle() }

        updateResizeBehavior()

        decoder.onDecodedFrame = { [weak self] image, w, h in
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.lastFrameSize?.0 != w || self.lastFrameSize?.1 != h
                self.lastFrameSize = (w, h)
                if changed {
                    self.updateResizeBehavior()
                }
                self.remoteView.display(frame: image)
            }
        }
        decoder.onRequestKeyframe = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onSendControl?(.requestKeyFrame(RequestKeyFrame(windowId: self.windowId)))
            }
        }

        if info.kind == .popup || info.kind == .dialog, let owner {
            repositionRelative(to: owner)
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func dpiScale(for info: WindowInfo) -> CGFloat {
        let dpi = info.dpi > 0 ? CGFloat(info.dpi) : 96.0
        return max(1.0, dpi / 96.0)
    }

    static func macContentSize(for info: WindowInfo) -> NSSize {
        let scale = dpiScale(for: info)
        var w = max(16.0, round(CGFloat(max(info.width, 1)) / scale))
        var h = max(16.0, round(CGFloat(max(info.height, 1)) / scale))
        if info.windowId == SyntheticWindow.primaryDesktop, let screen = NSScreen.main?.visibleFrame {
            let maxW = screen.width * 0.78
            let maxH = screen.height * 0.78
            let fit = min(1.0, min(maxW / w, maxH / h))
            w = max(320.0, round(w * fit))
            h = max(200.0, round(h * fit))
        }
        return NSSize(width: w, height: h)
    }

    private var isDesktop: Bool { windowId == SyntheticWindow.primaryDesktop }

    private var activeSourceSize: CGSize {
        if let (fw, fh) = lastFrameSize, fw > 0, fh > 0 {
            return CGSize(width: CGFloat(fw), height: CGFloat(fh))
        }
        return CGSize(width: CGFloat(max(info.width, 1)), height: CGFloat(max(info.height, 1)))
    }

    var videoRectInScreen: NSRect {
        guard let window else { return .zero }
        let rectInWin = remoteView.convert(remoteView.currentVideoRect, to: nil)
        return window.convertToScreen(rectInWin)
    }

    func updateResizeBehavior() {
        let src = activeSourceSize
        guard let window else { return }
        if info.kind == .popup {
            remoteView.updateDisplayGeometry(sourceSize: src, preserveAspect: false)
            return
        }
        let localScaleOnly = isDesktop || !syncWindowResize()
        if localScaleOnly && src.width > 0 && src.height > 0 {
            window.contentAspectRatio = NSSize(width: src.width, height: src.height)
        } else {
            window.resizeIncrements = NSSize(width: 1, height: 1)
        }
        remoteView.updateDisplayGeometry(sourceSize: src, preserveAspect: localScaleOnly)
    }

    func present(owner: RemoteWindowController?) {
        guard let window else { return }
        if info.kind == .popup {
            if let owner, let ownerWindow = owner.window {
                repositionRelative(to: owner)
                if window.parent !== ownerWindow {
                    ownerWindow.addChildWindow(window, ordered: .above)
                }
            }
            window.orderFront(nil)
        } else {
            if info.kind == .dialog, let owner {
                repositionRelative(to: owner)
            }
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(remoteView)
        }
    }

    func applyUpdate(_ update: WindowUpdated, owner: RemoteWindowController?) {
        guard let newInfo = update.window else { return }
        let oldInfo = self.info
        self.info = newInfo

        guard let window else { return }
        if newInfo.kind != .popup {
            let newTitle = newInfo.title.isEmpty ? newInfo.processName : newInfo.title
            if baseTitle != newTitle {
                baseTitle = newTitle
                updateWindowTitle()
            }
        }

        if newInfo.kind == .popup {
            if let owner, let ownerWindow = owner.window {
                repositionRelative(to: owner)
                if window.parent !== ownerWindow {
                    ownerWindow.addChildWindow(window, ordered: .above)
                }
            }
            return
        }

        let dimsChanged = newInfo.width != oldInfo.width || newInfo.height != oldInfo.height || newInfo.dpi != oldInfo.dpi
        if dimsChanged {
            updateResizeBehavior()
        }

        // In Local Scale Mode (and always for Full Desktop), never override the user's chosen Mac window size
        // unless Windows changed aspect ratio (e.g. emulator rotated portrait <-> landscape).
        if isDesktop || !syncWindowResize() {
            if dimsChanged && oldInfo.width > 0 && oldInfo.height > 0 && newInfo.width > 0 && newInfo.height > 0 {
                let oldRatio = CGFloat(oldInfo.width) / CGFloat(oldInfo.height)
                let newRatio = CGFloat(newInfo.width) / CGFloat(newInfo.height)
                if abs(oldRatio - newRatio) > 0.02 {
                    let current = window.contentLayoutRect.size
                    let area = current.width * current.height
                    let targetW = max(160.0, round(sqrt(area * newRatio)))
                    let targetH = max(100.0, round(targetW / newRatio))
                    applyProgrammaticContentSize(NSSize(width: targetW, height: targetH))
                }
            }
            return
        }

        // Sync Windows Resize Mode: anti-loop check for in-flight resize.
        let waitingForAck = update.ackResizeSeq < localResizeSeq
            && (lastResizeSentAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false)
        if isLiveResizing || waitingForAck {
            return
        }

        if dimsChanged {
            let targetSize = Self.macContentSize(for: newInfo)
            let currentSize = window.contentLayoutRect.size
            if abs(targetSize.width - currentSize.width) >= 2 || abs(targetSize.height - currentSize.height) >= 2 {
                applyProgrammaticContentSize(targetSize)
            }
        }
    }

    private func applyProgrammaticContentSize(_ targetSize: NSSize) {
        guard let window else { return }
        isApplyingRemoteGeometry = true
        let oldFrame = window.frame
        let newFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetSize)).size
        let newOriginY = oldFrame.maxY - newFrameSize.height
        let newFrame = NSRect(origin: NSPoint(x: oldFrame.minX, y: newOriginY), size: newFrameSize)
        window.setFrame(newFrame, display: true)
        isApplyingRemoteGeometry = false
    }

    func repositionRelative(to owner: RemoteWindowController) {
        guard let window else { return }
        let ownerVideoScreen = owner.videoRectInScreen
        let scaleX = ownerVideoScreen.width / CGFloat(max(owner.info.width, 1))
        let scaleY = ownerVideoScreen.height / CGFloat(max(owner.info.height, 1))

        let contentW = max(16.0, round(CGFloat(max(info.width, 1)) * scaleX))
        let contentH = max(16.0, round(CGFloat(max(info.height, 1)) * scaleY))

        let leftX = ownerVideoScreen.minX + CGFloat(info.offsetX) * scaleX
        // Windows offsetY grows downward from owner top; macOS screen Y grows upward.
        let topY = ownerVideoScreen.maxY - CGFloat(info.offsetY) * scaleY
        let contentOriginY = topY - contentH
        let contentScreenRect = NSRect(x: round(leftX), y: round(contentOriginY), width: contentW, height: contentH)
        let frameRect = window.frameRect(forContentRect: contentScreenRect)

        isApplyingRemoteGeometry = true
        window.setFrame(frameRect, display: true)
        isApplyingRemoteGeometry = false
    }

    func handleMediaFrame(_ frame: MediaFrame) {
        if !frame.header.flags.contains(.endOfStream) && !frame.payload.isEmpty {
            hudFramesInWindow += 1
            hudBytesInWindow += frame.payload.count
            hudLastCodec = frame.header.codec.displayName
        }
        decoder.decode(frame)
    }

    func updateHudVisibility() {
        let visible = info.kind != .popup && showPerformanceHud()
        remoteView.setHudVisible(visible)
        if visible {
            if hudTimer == nil {
                hudWindowStart = Date()
                hudFramesInWindow = 0
                hudBytesInWindow = 0
                hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshHudStats()
                    }
                }
            }
            refreshHudStats()
        } else {
            hudTimer?.invalidate()
            hudTimer = nil
        }
    }

    private func refreshHudStats() {
        let now = Date()
        let elapsed = max(0.05, now.timeIntervalSince(hudWindowStart))
        let fps = Double(hudFramesInWindow) / elapsed
        let mbps = (Double(hudBytesInWindow) * 8.0) / (elapsed * 1_000_000.0)
        hudWindowStart = now
        hudFramesInWindow = 0
        hudBytesInWindow = 0
        let w = lastFrameSize?.0 ?? UInt16(min(info.width, UInt32(UInt16.max)))
        let h = lastFrameSize?.1 ?? UInt16(min(info.height, UInt32(UInt16.max)))
        remoteView.updateHudText(PerformanceHUDFormatter.format(
            codecName: hudLastCodec,
            fps: fps,
            mbps: mbps,
            rttMs: currentRttMs(),
            width: w,
            height: h
        ))
    }

    func applyCursor(_ shape: CursorShape) {
        remoteView.applyCursorShape(shape)
    }

    var isAlwaysShowLocalCursor: Bool {
        remoteView.alwaysShowLocalCursor
    }

    func toggleAlwaysShowLocalCursor() {
        guard info.kind != .popup else { return }
        let next = !remoteView.alwaysShowLocalCursor
        remoteView.setAlwaysShowLocalCursor(next)
        showToast(
            next ? "🖱️ 已强制显示本地鼠标指针" : "已恢复跟随远端鼠标指针",
            style: .progress,
            autoHideSeconds: 2.0
        )
    }

    func showToast(_ text: String, style: TransferToastStyle, autoHideSeconds: TimeInterval?) {
        guard info.kind != .popup else { return }
        remoteView.showToast(text, style: style, autoHideSeconds: autoHideSeconds)
    }

    func setPointerLock(_ enabled: Bool) {
        guard info.kind != .popup else { return }
        remoteView.setGameLockEnabled(enabled)
    }

    func togglePointerLock() {
        guard info.kind != .popup else { return }
        remoteView.setGameLockEnabled(!remoteView.gameLockEnabled)
    }

    func unlockPointerIfNeeded() {
        if remoteView.gameLockEnabled {
            remoteView.setGameLockEnabled(false)
        }
    }

    func togglePinOnTop() {
        setPinnedOnTop(!isPinnedOnTop, silent: false)
    }

    func setPinnedOnTop(_ pinned: Bool, silent: Bool = false) {
        guard info.kind != .popup, let window else { return }
        guard pinned != isPinnedOnTop else { return }
        isPinnedOnTop = pinned
        // Keep floating window pinned on the current macOS Desktop/Space only (do not add .canJoinAllSpaces).
        window.level = pinned ? .floating : .normal
        updateWindowTitle()
        if !silent {
            showToast(
                pinned ? "📌 窗口已置顶（当前桌面）" : "窗口已取消置顶",
                style: .progress,
                autoHideSeconds: 1.8
            )
        }
        onPinOnTopChanged?()
        onLayoutChanged?(windowId)
    }

    func setAudioMuted(_ muted: Bool) {
        guard info.kind != .popup else { return }
        guard muted != isAudioMuted else { return }
        isAudioMuted = muted
        updateWindowTitle()
        onLayoutChanged?(windowId)
    }

    func snapshotLayout() -> SavedWindowLayout? {
        guard info.kind != .popup, let window else { return nil }
        return SavedWindowLayout(
            rect: window.frame,
            isPinnedOnTop: isPinnedOnTop,
            isAudioMuted: isAudioMuted
        )
    }

    func applySavedLayout(_ layout: SavedWindowLayout) {
        guard info.kind != .popup, let window else { return }
        let clamped = SavedWindowLayout.clampToActiveScreens(layout.rect)
        isApplyingRemoteGeometry = true
        window.setFrame(clamped, display: true)
        isApplyingRemoteGeometry = false
        setPinnedOnTop(layout.isPinnedOnTop, silent: true)
        setAudioMuted(layout.isAudioMuted)
    }

    private func scheduleLayoutSave() {
        guard info.kind != .popup else { return }
        layoutSaveTimer?.invalidate()
        layoutSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onLayoutChanged?(self.windowId)
            }
        }
    }

    private func updateWindowTitle() {
        guard info.kind != .popup, let window else { return }
        var tags: [String] = []
        if isPinnedOnTop {
            tags.append("置顶")
        }
        if isAudioMuted {
            tags.append("静音")
        }
        switch remoteView.gameLockState {
        case .off:
            break
        case .confinedVisible:
            tags.append("游戏锁定 · 菜单指针 · Ctrl+Option 释放")
        case .relativeLocked:
            tags.append("游戏锁定 · 3D 视角 · Ctrl+Option 释放")
        }
        if tags.isEmpty {
            window.title = baseTitle
        } else {
            window.title = "\(baseTitle) [\(tags.joined(separator: " · "))]"
        }
    }

    func forceCloseLocally() {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = nil
        layoutSaveTimer?.invalidate()
        layoutSaveTimer = nil
        hudTimer?.invalidate()
        hudTimer = nil
        unlockPointerIfNeeded()
        remoteView.releaseAllHeldKeys()
        decoder.invalidate()
        allowImmediateClose = true
        if let window, let parent = window.parent {
            parent.removeChildWindow(window)
        }
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard info.kind != .popup else { return }
        window?.makeFirstResponder(remoteView)
        onSendControl?(.focusWindow(FocusWindow(windowId: windowId, focused: true)))
    }

    func windowDidResignKey(_ notification: Notification) {
        unlockPointerIfNeeded()
        remoteView.releaseAllHeldKeys()
        if info.kind != .popup {
            onSendControl?(.focusWindow(FocusWindow(windowId: windowId, focused: false)))
        }
    }

    func windowWillClose(_ notification: Notification) {
        unlockPointerIfNeeded()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        isLiveResizing = true
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingRemoteGeometry, info.kind != .popup else { return }
        onOwnerMovedOrResized?(windowId)
        scheduleLayoutSave()
        if !isDesktop && syncWindowResize() {
            scheduleDebouncedResize()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingRemoteGeometry, info.kind != .popup else { return }
        onOwnerMovedOrResized?(windowId)
        scheduleLayoutSave()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        isLiveResizing = false
        guard !isApplyingRemoteGeometry, info.kind != .popup else { return }
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = nil
        scheduleLayoutSave()
        if !isDesktop && syncWindowResize() {
            sendCurrentSizeToHost()
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        // Request fresh IDR keyframe upon restoring minimized macOS window.
        onSendControl?(.requestKeyFrame(RequestKeyFrame(windowId: windowId)))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowImmediateClose {
            return true
        }
        // Full desktop view always detaches cleanly without closing anything on Windows.
        if isDesktop {
            onDetachRequested?(windowId)
            return false
        }
        // Option+Click red button detaches without closing the Windows app.
        if NSEvent.modifierFlags.contains(.option) {
            onDetachRequested?(windowId)
            return false
        }
        // Second click within 2 seconds forces local detach (escape hatch if Windows app hangs or shows hidden prompt).
        if let last = lastCloseAttemptAt, Date().timeIntervalSince(last) < 2.0 {
            onDetachRequested?(windowId)
            return false
        }
        lastCloseAttemptAt = Date()
        onSendControl?(.closeWindow(CloseWindow(windowId: windowId)))
        return false
    }

    private func scheduleDebouncedResize() {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.sendCurrentSizeToHost()
            }
        }
    }

    private func sendCurrentSizeToHost() {
        guard let window else { return }
        let contentSize = window.contentLayoutRect.size
        let scale = Self.dpiScale(for: info)
        let physW = UInt32(max(16, round(contentSize.width * scale)))
        let physH = UInt32(max(16, round(contentSize.height * scale)))
        localResizeSeq &+= 1
        lastResizeSentAt = Date()
        onSendControl?(.resizeWindow(ResizeWindow(
            windowId: windowId,
            width: physW,
            height: physH,
            resizeSeq: localResizeSeq
        )))
    }
}
