import AppKit
import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(hostName: String, codec: VideoCodec)
}

private struct RestoreWindowTarget: Equatable {
    let isDesktop: Bool
    let processName: String
    let title: String
}

private struct PendingPullTarget {
    let destinationURL: URL?
    let copyToPasteboard: Bool
    let completion: (@Sendable (Error?) -> Void)?
}

private struct IncomingPull {
    let requestId: UInt64
    let finalURL: URL
    let partialURL: URL
    let handle: FileHandle
    let expected: UInt64
    let customDestination: Bool
    let copyToPasteboard: Bool
    let completion: (@Sendable (Error?) -> Void)?
    var received: UInt64
    var lastProgressToastAt: Date
}

@MainActor
final class AppState {
    var settings: ClientSettings {
        didSet {
            SettingsStore.save(settings)
            clipboardMonitor.isEnabled = settings.syncClipboard
            audioPlayer.volume = settings.audioVolume
            if oldValue.syncWindowResize != settings.syncWindowResize {
                for (_, wc) in controllers {
                    wc.updateResizeBehavior()
                }
            }
            if oldValue.showPerformanceHud != settings.showPerformanceHud {
                for (_, wc) in controllers {
                    wc.updateHudVisibility()
                }
            }
            if oldValue.audioEnabled != settings.audioEnabled
                || oldValue.audioQuality != settings.audioQuality
                || oldValue.audioProcessOnly != settings.audioProcessOnly {
                applyAudioSetting()
            }
            if oldValue.videoProfile != settings.videoProfile || oldValue.adaptiveBitrate != settings.adaptiveBitrate {
                pushVideoConfig(windowId: 0)
            }
            if oldValue.autoWanOptimize != settings.autoWanOptimize {
                let nextWan = settings.autoWanOptimize && (connectedViaFallback || highRttConsecutiveCount >= 2)
                if nextWan != wanOptimizationActive {
                    wanOptimizationActive = nextWan
                    if settings.audioEnabled {
                        applyAudioSetting()
                    }
                    pushVideoConfig(windowId: 0)
                }
            }
            if !settings.autoReconnect && oldValue.autoReconnect {
                cancelReconnect()
            }
            if oldValue.shortcuts != settings.shortcuts {
                onShortcutsChanged?()
            }
            if settings.forwardNotifications && !oldValue.forwardNotifications {
                notificationForwarder.requestAuthorizationIfNeeded()
            }
        }
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var rttMs: Double?
    private(set) var availableWindows: [WindowInfo] = []
    private(set) var availableApps: [AppEntry] = []
    private(set) var discoveredHosts: [DiscoveredHost] = []
    private(set) var subscribedRootIds: Set<UInt64> = []
    private(set) var mutedWindowIds: Set<UInt64> = []
    private(set) var connectedHostVersion: String = ""
    private(set) var connectedHostCapabilities: UInt32 = 0
    private(set) var activeTransport: ActiveTransport?
    private(set) var connectedViaFallback: Bool = false
    private(set) var connectedEndpointHost: String = ""
    private(set) var wanOptimizationActive: Bool = false
    private(set) var lastBannerMessage: String = ""
    private(set) var lastBannerIsError: Bool = false

    var isReconnecting: Bool { reconnectTask != nil }
    private var isWakeConnecting = false
    private var wakeDeadline: Date?
    private var highRttConsecutiveCount = 0
    private var pendingPresetLayouts: [String: SavedWindowLayout] = [:]

    var isDesktopOpen: Bool {
        subscribedRootIds.contains(SyntheticWindow.primaryDesktop)
    }

    var pinnedApps: [AppEntry] {
        let pinnedSet = Set(settings.pinnedAppIds)
        return availableApps.filter { pinnedSet.contains($0.appId) }
    }

    private var connection: WinBridgeConnection?
    private var controllers: [UInt64: RemoteWindowController] = [:]
    private let clipboardMonitor = ClipboardMonitor()
    private let audioPlayer = AudioPlayer()
    private let hostDiscovery = HostDiscovery()
    private let gamepadMonitor = GamepadMonitor()
    private let notificationForwarder = NotificationForwarder()

    private var manualDisconnectRequested = false
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var pendingRestoreTargets: [RestoreWindowTarget] = []
    private var nextTransferId: UInt64 = 1
    private var activeTransferNames: [UInt64: String] = [:]
    private var activeTransferTargetWindow: [UInt64: UInt64] = [:]
    private var pendingPullTargets: [UInt64: PendingPullTarget] = [:]
    private var clipboardBatchFiles: [UInt64: [URL]] = [:]
    private var incomingPulls: [UInt64: IncomingPull] = [:]
    private var lastClipboardFilesChangeId: UInt64 = 0
    private(set) var lastHostClipboardNotice: ClipboardFilesNotice?
    var onHostFilesListed: ((ListHostFilesResponse) -> Void)?
    var onFilePullStatusChanged: ((String, Bool) -> Void)?
    private var lastAdaptivePush = Date.distantPast

    var onStateChanged: (() -> Void)?
    var onOpenManager: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?

    init() {
        self.settings = SettingsStore.load()
        clipboardMonitor.isEnabled = settings.syncClipboard
        audioPlayer.volume = settings.audioVolume
        clipboardMonitor.onLocalChange = { [weak self] sync in
            self?.sendControl(.clipboardSync(sync))
        }
        hostDiscovery.onHostsChanged = { [weak self] hosts in
            self?.discoveredHosts = hosts
            self?.onStateChanged?()
        }
        gamepadMonitor.shouldForward = { [weak self] in
            guard let self, case .connected = self.connectionState else { return false }
            return NSApp.keyWindow?.windowController is RemoteWindowController
        }
        gamepadMonitor.onGamepadState = { [weak self] state in
            self?.sendControl(.gamepadState(state))
        }
        notificationForwarder.prepareIfBundled()
        notificationForwarder.onNotificationClicked = { [weak self] windowId, processName, appName in
            self?.handleNotificationClicked(windowId: windowId, processName: processName, appName: appName)
        }
    }

    func startDiscovery() {
        hostDiscovery.start()
    }

    func stopDiscovery() {
        hostDiscovery.stop()
    }

    func selectDiscoveredHost(_ host: DiscoveredHost) {
        var s = settings
        s.host = host.host
        s.port = host.port
        s.useTls = host.tlsEnabled
        syncSelectedProfileFields(in: &s)
        settings = s
        setBanner("已选择局域网主机 \(host.name)（\(host.host):\(host.port)）", isError: false)
        onStateChanged?()
    }

    // MARK: - Multi-Host Profiles, Pairing Code & Wake-on-LAN

    var activeHostProfile: HostProfile? {
        settings.hostProfiles.first { $0.id == settings.selectedHostProfileId }
    }

    func syncSelectedProfileFields(in s: inout ClientSettings) {
        if let idx = s.hostProfiles.firstIndex(where: { $0.id == s.selectedHostProfileId }) {
            s.hostProfiles[idx].host = s.host
            s.hostProfiles[idx].fallbackHost = s.fallbackHost
            s.hostProfiles[idx].port = s.port
            s.hostProfiles[idx].useTls = s.useTls
            s.hostProfiles[idx].macAddress = s.macAddress
        } else {
            let id = s.selectedHostProfileId.isEmpty ? KeychainStore.defaultAccount : s.selectedHostProfileId
            s.selectedHostProfileId = id
            s.hostProfiles.append(HostProfile(
                id: id,
                name: s.host.isEmpty ? "默认主机" : s.host,
                host: s.host,
                fallbackHost: s.fallbackHost,
                port: s.port,
                useTls: s.useTls,
                macAddress: s.macAddress
            ))
        }
    }

    func selectHostProfile(id: String) {
        guard connectionState == .disconnected, !isReconnecting else {
            setBanner("请先断开当前连接再切换主机配置", isError: true)
            onStateChanged?()
            return
        }
        guard let profile = settings.hostProfiles.first(where: { $0.id == id }) else { return }
        var s = settings
        s.selectedHostProfileId = profile.id
        s.host = profile.host
        s.fallbackHost = profile.fallbackHost
        s.port = profile.port
        s.useTls = profile.useTls
        s.macAddress = profile.macAddress
        s.authToken = KeychainStore.loadToken(account: KeychainStore.accountName(forProfileId: profile.id)) ?? ""
        settings = s
        setBanner("已切换到主机配置「\(profile.name)」（\(profile.host):\(profile.port)）", isError: false)
        onStateChanged?()
    }

    func createHostProfile(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? (settings.host.isEmpty ? "新主机" : settings.host) : name
        let newId = UUID().uuidString.lowercased()
        var s = settings
        let profile = HostProfile(
            id: newId,
            name: finalName,
            host: s.host.trimmingCharacters(in: .whitespacesAndNewlines),
            fallbackHost: s.fallbackHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: s.port,
            useTls: s.useTls,
            macAddress: WakeOnLan.normalizeMac(s.macAddress) ?? s.macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        s.hostProfiles.append(profile)
        s.selectedHostProfileId = newId
        settings = s
        setBanner("已保存为主机配置「\(finalName)」", isError: false)
        onStateChanged?()
    }

    func deleteSelectedHostProfile() {
        guard connectionState == .disconnected, !isReconnecting else {
            setBanner("请先断开连接再删除主机配置", isError: true)
            onStateChanged?()
            return
        }
        guard settings.hostProfiles.count > 1 else {
            setBanner("至少保留一个主机配置", isError: true)
            onStateChanged?()
            return
        }
        var s = settings
        let removedId = s.selectedHostProfileId
        let removedName = s.hostProfiles.first(where: { $0.id == removedId })?.name ?? removedId
        s.hostProfiles.removeAll { $0.id == removedId }
        KeychainStore.deleteToken(account: KeychainStore.accountName(forProfileId: removedId))
        let next = s.hostProfiles[0]
        s.selectedHostProfileId = next.id
        s.host = next.host
        s.fallbackHost = next.fallbackHost
        s.port = next.port
        s.useTls = next.useTls
        s.macAddress = next.macAddress
        s.authToken = KeychainStore.loadToken(account: KeychainStore.accountName(forProfileId: next.id)) ?? ""
        settings = s
        setBanner("已删除主机配置「\(removedName)」，当前选中「\(next.name)」", isError: false)
        onStateChanged?()
    }

    @discardableResult
    func importPairingCode(_ raw: String) -> Bool {
        guard let parsed = PairingCode.parse(raw) else {
            setBanner("无法识别配对码（应以 winbridge:// 开头）", isError: true)
            onStateChanged?()
            return false
        }
        if connectionState != .disconnected {
            disconnect()
        }
        var s = settings
        let displayName = parsed.name ?? parsed.host
        let targetId: String
        if let existingIdx = s.hostProfiles.firstIndex(where: {
            $0.host.caseInsensitiveCompare(parsed.host) == .orderedSame && $0.port == parsed.port
        }) {
            targetId = s.hostProfiles[existingIdx].id
            if let explicitName = parsed.name, !explicitName.isEmpty {
                s.hostProfiles[existingIdx].name = explicitName
            }
            s.hostProfiles[existingIdx].host = parsed.host
            if let fb = parsed.fallbackHost {
                s.hostProfiles[existingIdx].fallbackHost = fb
            }
            s.hostProfiles[existingIdx].port = parsed.port
            s.hostProfiles[existingIdx].useTls = parsed.useTls
            if let mac = parsed.macAddress {
                s.hostProfiles[existingIdx].macAddress = mac
            }
        } else {
            targetId = UUID().uuidString.lowercased()
            s.hostProfiles.append(HostProfile(
                id: targetId,
                name: displayName,
                host: parsed.host,
                fallbackHost: parsed.fallbackHost ?? "",
                port: parsed.port,
                useTls: parsed.useTls,
                macAddress: parsed.macAddress ?? ""
            ))
        }
        s.selectedHostProfileId = targetId
        s.host = parsed.host
        if let fb = parsed.fallbackHost {
            s.fallbackHost = fb
        } else if let prof = s.hostProfiles.first(where: { $0.id == targetId }) {
            s.fallbackHost = prof.fallbackHost
        }
        s.port = parsed.port
        s.useTls = parsed.useTls
        if let mac = parsed.macAddress {
            s.macAddress = mac
        } else if let prof = s.hostProfiles.first(where: { $0.id == targetId }) {
            s.macAddress = prof.macAddress
        }
        if let token = parsed.token {
            s.authToken = token
        } else {
            s.authToken = KeychainStore.loadToken(account: KeychainStore.accountName(forProfileId: targetId)) ?? ""
        }
        if let fp = parsed.fingerprint {
            let key = CertificateFingerprint.hostKey(host: parsed.host, port: parsed.port)
            s.trustedFingerprints[key] = fp
            let fbTrimmed = s.fallbackHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fbTrimmed.isEmpty {
                let fbKey = CertificateFingerprint.hostKey(host: fbTrimmed, port: parsed.port)
                s.trustedFingerprints[fbKey] = fp
            }
        }
        settings = s

        var notes: [String] = []
        if parsed.token != nil { notes.append("Token") }
        if parsed.fingerprint != nil { notes.append("TLS 指纹") }
        if parsed.macAddress != nil { notes.append("WoL MAC") }
        if parsed.fallbackHost != nil { notes.append("备用地址") }
        let suffix = notes.isEmpty ? "" : "（已填入 \(notes.joined(separator: " / "))）"
        ClientLogger.shared.info("Imported pairing code for \(displayName) (\(parsed.host):\(parsed.port))")
        setBanner("✓ 已导入配对配置「\(displayName)」\(suffix)，点击连接即可", isError: false)
        onStateChanged?()
        return true
    }

    func wakeAndConnect() {
        guard connectionState == .disconnected else {
            setBanner("当前已连接或正在连接中", isError: false)
            onStateChanged?()
            return
        }
        let rawMac = settings.macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedMac = WakeOnLan.normalizeMac(rawMac) else {
            setBanner("未记录有效的 Windows 网卡 MAC 地址：请先连接一次自动获取，或在 MAC 栏手动填写", isError: true)
            onStateChanged?()
            return
        }
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let targets = try WakeOnLan.send(macAddress: normalizedMac, hostHint: host)
            ClientLogger.shared.info("Sent WoL magic packet to \(normalizedMac) via \(targets.joined(separator: ", "))")
            cancelReconnect()
            manualDisconnectRequested = false
            isWakeConnecting = true
            wakeDeadline = Date().addingTimeInterval(60)
            reconnectAttempt = 0
            setBanner("⚡ 已向 \(normalizedMac) 发送唤醒包，等待 Windows 开机上线并自动连接…", isError: false)
            onStateChanged?()
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.connectionState == .disconnected else { return }
                self.connect(isAutoReconnect: true)
            }
        } catch {
            ClientLogger.shared.error("WoL send failed: \(error.localizedDescription)")
            setBanner("唤醒失败：\(error.localizedDescription)", isError: true)
            onStateChanged?()
        }
    }

    // MARK: - Always-on-Top PiP & Per-Window Audio Mute

    func isWindowMuted(_ windowId: UInt64) -> Bool {
        mutedWindowIds.contains(windowId)
    }

    func isActiveWindowMuted() -> Bool {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController else { return false }
        return mutedWindowIds.contains(wc.windowId)
    }

    func isActiveWindowPinnedOnTop() -> Bool {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController else { return false }
        return wc.isPinnedOnTop
    }

    func isActiveWindowAlwaysShowingLocalCursor() -> Bool {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController else { return false }
        return wc.isAlwaysShowLocalCursor
    }

    func toggleAlwaysShowLocalCursorForActiveWindow() {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController else {
            setBanner("请先选中一个正在投射的 Windows 窗口", isError: true)
            onStateChanged?()
            return
        }
        wc.toggleAlwaysShowLocalCursor()
    }

    func togglePinOnTopForActiveWindow() {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController else {
            setBanner("请先选中一个正在投射的 Windows 窗口", isError: true)
            onStateChanged?()
            return
        }
        wc.togglePinOnTop()
    }

    func toggleMuteForActiveWindow() {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController else {
            setBanner("请先选中一个正在投射的 Windows 窗口", isError: true)
            onStateChanged?()
            return
        }
        toggleMute(windowId: wc.windowId)
    }

    func toggleMute(windowId: UInt64) {
        let nowMuted: Bool
        if mutedWindowIds.contains(windowId) {
            mutedWindowIds.remove(windowId)
            nowMuted = false
        } else {
            mutedWindowIds.insert(windowId)
            nowMuted = true
        }
        controllers[windowId]?.setAudioMuted(nowMuted)
        if settings.audioEnabled {
            applyAudioSetting()
            let toast = nowMuted ? "🔇 当前窗口已静音" : "🔊 当前窗口已恢复声音"
            controllers[windowId]?.showToast(toast, style: .progress, autoHideSeconds: 1.8)
            setBanner(toast, isError: false)
        } else {
            let toast = nowMuted ? "🔇 已标记窗口静音（开启 Windows 音频后生效）" : "🔊 已取消窗口静音标记"
            controllers[windowId]?.showToast(toast, style: .progress, autoHideSeconds: 2.0)
            setBanner(toast, isError: false)
        }
        onStateChanged?()
    }

    func setTransportPreference(_ pref: TransportPreference) {
        var s = settings
        s.transportPreference = pref
        settings = s
        setBanner("传输通道已设为：\(pref.title)（重新连接后生效）", isError: false)
        onStateChanged?()
    }

    func toggleAutoWanOptimize() {
        var s = settings
        s.autoWanOptimize.toggle()
        settings = s
        setBanner(
            s.autoWanOptimize
                ? "已开启外网自动弱网优化（备用地址或 RTT ≥ 30 ms 时自动启用自适应码率 + Opus 64k）"
                : "已关闭外网自动弱网优化",
            isError: false
        )
        onStateChanged?()
    }

    var effectiveAudioQuality: AudioQualityPreference {
        if wanOptimizationActive && settings.autoWanOptimize {
            return .opus64
        }
        return settings.audioQuality
    }

    var effectiveAdaptiveBitrate: Bool {
        settings.adaptiveBitrate || (wanOptimizationActive && settings.autoWanOptimize)
    }

    private func evaluateWanOptimization(rttMs rtt: Double) {
        guard settings.autoWanOptimize, !wanOptimizationActive, case .connected = connectionState else { return }
        if rtt >= 30.0 {
            highRttConsecutiveCount += 1
            if highRttConsecutiveCount >= 2 {
                wanOptimizationActive = true
                if settings.audioEnabled {
                    applyAudioSetting()
                }
                pushVideoConfig(windowId: 0)
                setBanner(
                    "🌐 检测到较高延迟（RTT \(Int(rtt.rounded())) ms），已自动启用弱网优化（自适应码率 + Opus 64k）",
                    isError: false
                )
                onStateChanged?()
            }
        } else {
            highRttConsecutiveCount = 0
        }
    }

    func toggleAudioEnabled() {
        var s = settings
        s.audioEnabled.toggle()
        settings = s
        onStateChanged?()
    }

    func setVideoProfile(_ profile: VideoProfilePreference) {
        var s = settings
        s.videoProfile = profile
        settings = s
        let adapt = s.adaptiveBitrate ? "，自适应码率开" : "，自适应码率关"
        setBanner("画质已设为\(profile.title)\(adapt)", isError: false)
        onStateChanged?()
    }

    func setVideoProfileForActiveProcess(_ profile: VideoProfilePreference) {
        guard let name = activeRemoteProcessName(), !name.isEmpty else {
            setBanner("请先选中一个正在投射的窗口，再按进程记住画质", isError: true)
            onStateChanged?()
            return
        }
        let key = name.lowercased()
        var s = settings
        s.processVideoProfiles[key] = profile
        settings = s
        if let wc = NSApp.keyWindow?.windowController as? RemoteWindowController {
            pushVideoConfig(windowId: wc.windowId)
        }
        setBanner("已记住：\(name) 使用\(profile.title)画质", isError: false)
        onStateChanged?()
    }

    func toggleAdaptiveBitrate() {
        var s = settings
        s.adaptiveBitrate.toggle()
        settings = s
        setBanner(s.adaptiveBitrate ? "已开启自适应码率（队列积压或 RTT 升高时降码率）" : "已关闭自适应码率", isError: false)
        onStateChanged?()
    }

    func videoProfile(for info: WindowInfo) -> VideoProfilePreference {
        let key = info.processName.lowercased()
        if !key.isEmpty, let saved = settings.processVideoProfiles[key] {
            return saved
        }
        return settings.videoProfile
    }

    func togglePerformanceHud() {
        var s = settings
        s.showPerformanceHud.toggle()
        settings = s
        onStateChanged?()
    }

    func toggleForwardNotifications() {
        var s = settings
        s.forwardNotifications.toggle()
        settings = s
        if s.forwardNotifications {
            notificationForwarder.requestAuthorizationIfNeeded()
        }
        setBanner(
            s.forwardNotifications
                ? "已开启 Windows 通知转发（收到通知时推送至 macOS 通知中心，点击可直达窗口）"
                : "已关闭 Windows 通知转发",
            isError: false
        )
        onStateChanged?()
    }

    private func handleHostNotification(_ note: HostNotification) {
        guard settings.forwardNotifications else { return }
        let formatted = NotificationForwarder.formatBanner(from: note)
        ClientLogger.shared.info(
            "HostNotification id=\(note.notificationId) app=\"\(note.appName)\" proc=\"\(note.processName)\" wid=0x\(String(note.windowId, radix: 16))"
        )
        notificationForwarder.post(note)
        let preview = formatted.subtitle.isEmpty ? formatted.body : "\(formatted.subtitle) — \(formatted.body)"
        setBanner("🔔 [\(formatted.title)] \(preview)", isError: false)
        onStateChanged?()
    }

    private func handleNotificationClicked(windowId: UInt64, processName: String, appName: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard case .connected = connectionState else {
            onOpenManager?()
            return
        }
        if windowId != 0, let existing = controllers[windowId] {
            existing.present(owner: nil)
            sendControl(.windowAction(WindowAction(windowId: windowId, action: .bringToFront)))
            return
        }
        if let target = NotificationForwarder.selectTargetWindow(
            windowId: windowId,
            processName: processName,
            appName: appName,
            availableWindows: availableWindows
        ) {
            focusOrSubscribe(target)
            return
        }
        refreshWindowList()
        onOpenManager?()
    }

    func mouseSensitivity(forProcess processName: String) -> Float {
        let key = processName.lowercased()
        if !key.isEmpty, let saved = settings.processMouseSensitivity[key] {
            return saved
        }
        return settings.mouseSensitivity
    }

    func setMouseSensitivity(_ value: Float, forProcess processName: String?) {
        let clamped = max(0.1, min(4.0, value))
        var s = settings
        s.mouseSensitivity = clamped
        if let proc = processName?.lowercased(), !proc.isEmpty {
            s.processMouseSensitivity[proc] = clamped
        }
        settings = s
    }

    func activeRemoteProcessName() -> String? {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController else { return nil }
        return wc.info.processName.isEmpty ? nil : wc.info.processName
    }

    func isAutoGameLockEnabled(forProcess processName: String) -> Bool {
        let key = processName.lowercased()
        return !key.isEmpty && (settings.processAutoGameLock[key] == true)
    }

    func toggleAutoGameLockForActiveWindow() {
        guard let wc = NSApp.keyWindow?.windowController as? RemoteWindowController,
              !wc.info.processName.isEmpty else {
            setBanner("请先选中一个正在投射的 Windows 游戏窗口", isError: true)
            onStateChanged?()
            return
        }
        let key = wc.info.processName.lowercased()
        var s = settings
        let next = !(s.processAutoGameLock[key] == true)
        s.processAutoGameLock[key] = next
        settings = s
        setBanner(
            next
                ? "已记住：下次打开 \(wc.info.processName) 时自动开启游戏鼠标锁定"
                : "已取消 \(wc.info.processName) 的自动游戏鼠标锁定",
            isError: false
        )
        onStateChanged?()
    }

    private func applyAudioSetting() {
        guard case .connected = connectionState else {
            audioPlayer.setEnabled(false)
            return
        }
        audioPlayer.setEnabled(settings.audioEnabled)
        let quality = effectiveAudioQuality
        sendControl(.setAudioConfig(SetAudioConfig(
            enabled: settings.audioEnabled,
            codec: quality.audioCodec,
            bitrateKbps: quality.bitrateKbps,
            scope: settings.audioProcessOnly ? 1 : 0,
            mutedWindowIds: Array(mutedWindowIds).sorted()
        )))
    }

    func toggleAudioProcessOnly() {
        var s = settings
        s.audioProcessOnly.toggle()
        settings = s
        setBanner(
            s.audioProcessOnly
                ? "只采集已投射窗口的进程声音。若系统不支持进程回环，会自动退回整机声音。"
                : "已改回采集整机系统声音",
            isError: false
        )
        onStateChanged?()
    }

    func pushVideoConfig(windowId: UInt64, rttOnly: Bool = false) {
        guard case .connected = connectionState else { return }
        let profile: VideoProfile
        if rttOnly {
            profile = .unspecified
        } else if windowId != 0, let info = videoInfo(for: windowId) {
            profile = videoProfile(for: info).protoValue
        } else {
            profile = settings.videoProfile.protoValue
        }
        let rtt = UInt32(min(10_000, max(0, (rttMs ?? 0).rounded())))
        sendControl(.setVideoConfig(SetVideoConfig(
            windowId: windowId,
            profile: profile,
            targetFps: 0,
            maxBitrateKbps: 0,
            adaptive: effectiveAdaptiveBitrate,
            rttMs: rtt
        )))
    }

    private func pushAdaptiveRttIfNeeded() {
        guard effectiveAdaptiveBitrate, case .connected = connectionState else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAdaptivePush) >= 2 else { return }
        lastAdaptivePush = now
        pushVideoConfig(windowId: 0, rttOnly: true)
    }

    private func videoInfo(for windowId: UInt64) -> WindowInfo? {
        if let info = controllers[windowId]?.info {
            return info
        }
        return availableWindows.first { $0.windowId == windowId }
    }

    // MARK: - Connection Lifecycle & Auto-Reconnect

    func connect(isAutoReconnect: Bool = false) {
        guard connectionState == .disconnected else { return }
        if !isAutoReconnect {
            cancelReconnect()
            manualDisconnectRequested = false
            reconnectAttempt = 0
            pendingRestoreTargets.removeAll()
        }
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackHost = settings.fallbackHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty || !fallbackHost.isEmpty else {
            setBanner("请输入 Windows 主机内网 IP 或从局域网发现中选择", isError: true)
            return
        }
        let primaryHost = host.isEmpty ? fallbackHost : host
        let secondaryHost = host.isEmpty ? "" : fallbackHost

        connectionState = .connecting
        ClientLogger.shared.info(
            "Connecting to \(primaryHost):\(settings.port) fallback=\(secondaryHost) tls=\(settings.useTls) auto=\(isAutoReconnect)"
        )
        let fbHint = secondaryHost.isEmpty ? "" : "（备用 \(secondaryHost)）"
        setBanner(
            isAutoReconnect
                ? "正在自动重连 \(primaryHost):\(settings.port)\(fbHint)（第 \(reconnectAttempt) 次）…"
                : "正在连接 \(primaryHost):\(settings.port)\(fbHint)…",
            isError: false
        )
        onStateChanged?()

        let conn = WinBridgeConnection()
        self.connection = conn

        conn.onControlMessage = { [weak self, weak conn] msg in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.handleControlMessage(msg)
            }
        }
        let player = self.audioPlayer
        conn.onMediaFrame = { [weak self, weak conn] frame in
            guard let conn, !conn.cancelledOrDisconnected else { return }
            if frame.header.codec == .audioPcmS16Le || frame.header.codec == .audioOpus {
                player.enqueue(frame: frame)
                return
            }
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.controllers[frame.header.windowId]?.handleMediaFrame(frame)
            }
        }
        conn.onRttUpdated = { [weak self, weak conn] rtt in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.rttMs = rtt
                self.evaluateWanOptimization(rttMs: rtt)
                self.onStateChanged?()
                self.pushAdaptiveRttIfNeeded()
            }
        }
        conn.onDisconnected = { [weak self, weak conn] error in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.handleDisconnected(error: error)
            }
        }

        let primaryKey = CertificateFingerprint.hostKey(host: primaryHost, port: settings.port)
        let fallbackKey = secondaryHost.isEmpty ? nil : CertificateFingerprint.hostKey(host: secondaryHost, port: settings.port)
        let primaryExpectedFp = settings.trustedFingerprints[primaryKey] ?? fallbackKey.flatMap { settings.trustedFingerprints[$0] }
        let fallbackExpectedFp = fallbackKey.flatMap { settings.trustedFingerprints[$0] } ?? settings.trustedFingerprints[primaryKey]
        let displayScale = Float(NSScreen.main?.backingScaleFactor ?? 2.0)
        let config = ConnectionConfig(
            host: primaryHost,
            fallbackHost: secondaryHost,
            port: settings.port,
            authToken: settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines),
            useTls: settings.useTls,
            transport: settings.transportPreference,
            expectedFingerprint: primaryExpectedFp,
            fallbackExpectedFingerprint: fallbackExpectedFp,
            clientName: Host.current().localizedName ?? "macOS",
            displayScale: displayScale,
            supportedCodecs: settings.codecPreference.offeredCodecs
        )

        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await conn.connect(config: config)
                guard self.connection === conn, !self.manualDisconnectRequested, !Task.isCancelled else {
                    conn.onDisconnected = nil
                    conn.disconnect(error: nil)
                    return
                }
                self.connectTask = nil
                let ack = outcome.ack
                var updatedSettings = self.settings
                var settingsModified = false
                if let fp = outcome.tlsFingerprint {
                    let connectedKey = CertificateFingerprint.hostKey(host: outcome.connectedHost, port: self.settings.port)
                    updatedSettings.trustedFingerprints[connectedKey] = fp
                    updatedSettings.trustedFingerprints[primaryKey] = fp
                    if let fbKey = fallbackKey {
                        updatedSettings.trustedFingerprints[fbKey] = fp
                    }
                    settingsModified = true
                }
                if let detectedMac = WakeOnLan.normalizeMac(ack.macAddress),
                   updatedSettings.macAddress != detectedMac {
                    updatedSettings.macAddress = detectedMac
                    self.syncSelectedProfileFields(in: &updatedSettings)
                    settingsModified = true
                }
                if settingsModified {
                    self.settings = updatedSettings
                }
                self.isWakeConnecting = false
                self.wakeDeadline = nil
                self.reconnectAttempt = 0
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                self.connectedHostVersion = ack.hostVersion
                self.connectedHostCapabilities = ack.capabilities
                self.activeTransport = outcome.transport
                self.connectedViaFallback = outcome.usedFallbackHost
                self.connectedEndpointHost = outcome.connectedHost
                self.highRttConsecutiveCount = 0
                self.wanOptimizationActive = outcome.usedFallbackHost && self.settings.autoWanOptimize
                self.connectionState = .connected(hostName: ack.hostName, codec: ack.selectedCodec)
                self.rttMs = nil
                let transportNote: String
                switch outcome.transport {
                case .quic:
                    transportNote = " · QUIC 多流"
                case .tcp:
                    transportNote = outcome.fellBackToTcp ? " · TCP (QUIC 回退)" : " · TCP"
                }
                let fallbackNote = outcome.usedFallbackHost ? " · 备用地址(\(outcome.connectedHost))" : ""
                let wanNote = self.wanOptimizationActive ? " · 弱网优化" : ""
                let tlsNote: String
                if let fp = outcome.tlsFingerprint {
                    let shortFp = CertificateFingerprint.shortDisplay(fp)
                    tlsNote = outcome.isFirstTrust ? " · TLS 首次信任 \(shortFp)" : " · TLS 已验证"
                } else {
                    tlsNote = " · 明文"
                }
                let versionNotice: String
                if ack.hostVersion.isEmpty
                    || (ack.capabilities & (ProtocolCapabilities.perWindowMute | ProtocolCapabilities.wolMac)) == 0 {
                    versionNotice = " · 提示：Windows 端版本较旧，更新 win-host.exe 可启用 QUIC / 单窗静音 / 自动 MAC"
                } else {
                    versionNotice = " · v\(ack.hostVersion)"
                }
                ClientLogger.shared.info(
                    "Connected to \(ack.hostName) endpoint=\(outcome.connectedHost) fallback=\(outcome.usedFallbackHost) wanOpt=\(self.wanOptimizationActive) transport=\(outcome.transport.rawValue) fellBack=\(outcome.fellBackToTcp) v=\(ack.hostVersion) caps=\(ack.capabilities) mac=\(ack.macAddress) codec=\(ack.selectedCodec.displayName)\(tlsNote)"
                )
                self.setBanner(
                    "已连接到 \(ack.hostName)（\(ack.selectedCodec.displayName)\(transportNote)\(fallbackNote)\(wanNote)\(tlsNote)\(versionNotice)）",
                    isError: false
                )
                self.clipboardMonitor.start()
                self.gamepadMonitor.start()
                if self.settings.forwardNotifications {
                    self.notificationForwarder.requestAuthorizationIfNeeded()
                }
                if self.settings.audioEnabled {
                    self.applyAudioSetting()
                }
                self.pushVideoConfig(windowId: 0)
                self.refreshWindowList()
                self.refreshAppList()
                self.onStateChanged?()
            } catch {
                conn.onDisconnected = nil
                conn.disconnect(error: nil)
                guard self.connection === conn else { return }
                self.connection = nil
                self.connectTask = nil
                self.connectionState = .disconnected
                ClientLogger.shared.error("Connect failed: \(error.localizedDescription)")
                self.setBanner("连接失败：\(error.localizedDescription)", isError: true)
                self.onStateChanged?()
                if case ConnectionError.certificateMismatch(let mismatchKey, let expected, let actual) = error {
                    self.cancelReconnect()
                    self.promptCertificateMismatch(hostKey: mismatchKey, expected: expected, actual: actual)
                } else if isAutoReconnect && self.shouldAutoReconnect(for: error) {
                    self.scheduleAutoReconnect(lastError: error)
                }
            }
        }
    }

    func disconnect() {
        manualDisconnectRequested = true
        cancelReconnect()
        connectTask?.cancel()
        connectTask = nil
        pendingRestoreTargets.removeAll()
        if let active = connection {
            active.disconnect(error: nil)
        } else if connectionState != .disconnected {
            handleDisconnected(error: nil)
        } else {
            setBanner("已断开连接", isError: false)
            onStateChanged?()
        }
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isWakeConnecting = false
        wakeDeadline = nil
    }

    func resetTrustedFingerprintForCurrentHost() {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = settings.fallbackHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty || !fallback.isEmpty else { return }
        var s = settings
        var removed: [String] = []
        if !host.isEmpty {
            let key = CertificateFingerprint.hostKey(host: host, port: settings.port)
            if s.trustedFingerprints.removeValue(forKey: key) != nil {
                removed.append(key)
            }
        }
        if !fallback.isEmpty {
            let fbKey = CertificateFingerprint.hostKey(host: fallback, port: settings.port)
            if s.trustedFingerprints.removeValue(forKey: fbKey) != nil {
                removed.append(fbKey)
            }
        }
        if !removed.isEmpty {
            settings = s
            setBanner("已清除 \(removed.joined(separator: "、")) 的已信任 TLS 指纹，下次连接将重新校验并记住", isError: false)
        } else {
            setBanner("当前主机尚未保存过 TLS 证书指纹", isError: false)
        }
        onStateChanged?()
    }

    private func shouldAutoReconnect(for error: Error?) -> Bool {
        if manualDisconnectRequested { return false }
        let allowWake = isWakeConnecting && (wakeDeadline.map { Date() < $0 } ?? false)
        guard settings.autoReconnect || allowWake, let error else {
            if isWakeConnecting {
                isWakeConnecting = false
                wakeDeadline = nil
            }
            return false
        }
        if let ce = error as? ConnectionError {
            switch ce {
            case .handshakeRejected, .certificateMismatch, .localNetworkProhibited, .invalidEndpoint:
                return false
            default:
                return true
            }
        }
        return true
    }

    private func scheduleAutoReconnect(lastError: Error) {
        let allowWake = isWakeConnecting && (wakeDeadline.map { Date() < $0 } ?? false)
        guard (settings.autoReconnect || allowWake), !manualDisconnectRequested else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delaySecs = allowWake ? min(4, max(2, reconnectAttempt)) : Self.reconnectDelaySeconds(forAttempt: reconnectAttempt)
        let attempt = reconnectAttempt
        if allowWake {
            let remaining = max(1, Int(ceil((wakeDeadline ?? Date()).timeIntervalSinceNow)))
            setBanner("⚡ 等待 Windows 唤醒上线中（第 \(attempt) 次尝试，剩余约 \(remaining) 秒）…", isError: false)
        } else {
            setBanner(
                "连接异常（\(lastError.localizedDescription)），\(delaySecs) 秒后自动重连（第 \(attempt) 次）…",
                isError: true
            )
        }
        onStateChanged?()

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySecs) * 1_000_000_000)
            guard let self, !Task.isCancelled, self.connectionState == .disconnected else { return }
            self.connect(isAutoReconnect: true)
        }
    }

    nonisolated static func reconnectDelaySeconds(forAttempt attempt: Int) -> Int {
        switch max(1, attempt) {
        case 1: return 1
        case 2: return 2
        case 3: return 4
        case 4: return 8
        default: return 15
        }
    }

    private func snapshotWindowsForRestore() -> [RestoreWindowTarget] {
        var targets: [RestoreWindowTarget] = []
        if subscribedRootIds.contains(SyntheticWindow.primaryDesktop) {
            targets.append(RestoreWindowTarget(isDesktop: true, processName: "", title: ""))
        }
        for id in subscribedRootIds where id != SyntheticWindow.primaryDesktop {
            if let wc = controllers[id], wc.info.kind != .popup {
                targets.append(RestoreWindowTarget(
                    isDesktop: false,
                    processName: wc.info.processName,
                    title: wc.info.title
                ))
            }
        }
        return targets
    }

    private func restoreWindowsIfPending(from windows: [WindowInfo]) {
        guard !pendingRestoreTargets.isEmpty else { return }
        let targets = pendingRestoreTargets
        pendingRestoreTargets.removeAll()
        var restoredIds = Set<UInt64>()
        for target in targets {
            if target.isDesktop {
                if !isDesktopOpen {
                    toggleDesktopView()
                }
                continue
            }
            let exact = windows.first {
                !restoredIds.contains($0.windowId)
                    && $0.processName.caseInsensitiveCompare(target.processName) == .orderedSame
                    && $0.title == target.title
            }
            let byProcess = exact ?? windows.first {
                !restoredIds.contains($0.windowId)
                    && !target.processName.isEmpty
                    && $0.processName.caseInsensitiveCompare(target.processName) == .orderedSame
            }
            if let match = byProcess {
                restoredIds.insert(match.windowId)
                subscribeWindow(match)
            }
        }
    }

    private func promptCertificateMismatch(hostKey: String, expected: String, actual: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Windows 主机 TLS 证书指纹发生变化"
        alert.informativeText = """
        目标主机：\(hostKey)

        上次信任指纹：
        \(expected)

        当前收到指纹：
        \(actual)

        如果您刚在 Windows 端重装了系统或重新生成了证书，可点击「信任新证书并重连」；否则请取消连接以防中间人攻击。
        """
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "信任新证书并重连")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            var s = settings
            s.trustedFingerprints[hostKey] = actual
            settings = s
            connect()
        }
    }

    private func handleDisconnected(error: Error?) {
        let shouldReconnect = shouldAutoReconnect(for: error)
        if shouldReconnect && pendingRestoreTargets.isEmpty {
            pendingRestoreTargets = snapshotWindowsForRestore()
        }

        clipboardMonitor.stop()
        gamepadMonitor.stop()
        audioPlayer.stop()
        connectTask?.cancel()
        connectTask = nil
        connection = nil
        connectionState = .disconnected
        rttMs = nil
        availableWindows.removeAll()
        availableApps.removeAll()
        subscribedRootIds.removeAll()
        mutedWindowIds.removeAll()
        connectedHostVersion = ""
        connectedHostCapabilities = 0
        activeTransport = nil
        connectedViaFallback = false
        connectedEndpointHost = ""
        wanOptimizationActive = false
        highRttConsecutiveCount = 0
        pendingPresetLayouts.removeAll()
        activeTransferNames.removeAll()
        activeTransferTargetWindow.removeAll()
        for (_, pending) in pendingPullTargets {
            pending.completion?(ConnectionError.connectionClosed)
        }
        pendingPullTargets.removeAll()
        clipboardBatchFiles.removeAll()
        lastHostClipboardNotice = nil
        lastClipboardFilesChangeId = 0
        for (_, pull) in incomingPulls {
            try? pull.handle.close()
            try? FileManager.default.removeItem(at: pull.partialURL)
            pull.completion?(ConnectionError.connectionClosed)
        }
        incomingPulls.removeAll()

        for (_, controller) in controllers {
            controller.forceCloseLocally()
        }
        controllers.removeAll()

        if let error {
            ClientLogger.shared.error("Disconnected: \(error.localizedDescription)")
            if shouldReconnect {
                scheduleAutoReconnect(lastError: error)
                return
            }
            setBanner("连接已断开：\(error.localizedDescription)", isError: true)
        } else {
            ClientLogger.shared.info("Disconnected cleanly")
            setBanner("已断开连接", isError: false)
        }
        onStateChanged?()
    }

    // MARK: - Window Actions

    func refreshWindowList() {
        guard case .connected = connectionState else { return }
        sendControl(.listWindowsReq(ListWindowsRequest(includeIcons: true)))
    }

    func refreshAppList() {
        guard case .connected = connectionState else { return }
        sendControl(.listAppsReq(ListAppsRequest(includeIcons: true)))
    }

    func toggleDesktopView() {
        guard case .connected = connectionState else { return }
        if isDesktopOpen {
            unsubscribeWindow(SyntheticWindow.primaryDesktop)
        } else {
            ClientLogger.shared.info("Subscribing primary desktop")
            subscribedRootIds.insert(SyntheticWindow.primaryDesktop)
            sendControl(.subscribeWindow(SubscribeWindow(
                windowId: SyntheticWindow.primaryDesktop,
                targetFps: settings.targetFps,
                maxBitrateKbps: 0,
                followPopups: false,
                captureMode: .monitorCrop
            )))
            onStateChanged?()
        }
    }

    func isPinned(_ appId: String) -> Bool {
        settings.pinnedAppIds.contains(appId)
    }

    func togglePin(_ appId: String) {
        var s = settings
        if let idx = s.pinnedAppIds.firstIndex(of: appId) {
            s.pinnedAppIds.remove(at: idx)
        } else {
            s.pinnedAppIds.append(appId)
        }
        settings = s
        onStateChanged?()
    }

    func captureMode(forApp app: AppEntry) -> CaptureMode {
        if let saved = settings.appCaptureModes[app.appId] {
            return saved
        }
        let lower = app.name.lowercased()
        if lower.contains("mumu") || lower.contains("雷电") || lower.contains("bluestacks") || lower.contains("steam") {
            return .monitorCrop
        }
        return .window
    }

    func setCaptureMode(_ mode: CaptureMode, forApp app: AppEntry) {
        var s = settings
        s.appCaptureModes[app.appId] = mode
        settings = s
        onStateChanged?()
    }

    func launchApp(_ app: AppEntry) {
        guard case .connected = connectionState else { return }
        let mode = captureMode(forApp: app)
        setBanner("正在启动「\(app.name)」，等待新窗口自动弹出…", isError: false)
        sendControl(.launchApp(LaunchApp(
            appId: app.appId,
            autoSubscribe: true,
            targetFps: settings.targetFps,
            maxBitrateKbps: 0,
            followPopups: settings.followPopups,
            captureMode: mode
        )))
        onStateChanged?()
    }

    func captureMode(for info: WindowInfo) -> CaptureMode {
        let key = info.processName.lowercased()
        if let saved = settings.processCaptureModes[key] {
            return saved
        }
        if key.contains("mumu") || key.contains("nemu") || key.contains("dnplayer") || key.contains("bluestacks") {
            return .monitorCrop
        }
        return .window
    }

    func setCaptureMode(_ mode: CaptureMode, for info: WindowInfo) {
        let key = info.processName.lowercased()
        if !key.isEmpty {
            var s = settings
            s.processCaptureModes[key] = mode
            settings = s
        }
        if subscribedRootIds.contains(info.windowId) {
            subscribeWindow(info)
        } else {
            onStateChanged?()
        }
    }

    func subscribeWindow(_ info: WindowInfo) {
        guard case .connected = connectionState else { return }
        subscribedRootIds.insert(info.windowId)
        let mode = captureMode(for: info)
        ClientLogger.shared.info("Subscribing window 0x\(String(info.windowId, radix: 16)) (\(info.processName)) mode=\(mode)")
        sendControl(.subscribeWindow(SubscribeWindow(
            windowId: info.windowId,
            targetFps: settings.targetFps,
            maxBitrateKbps: 0,
            followPopups: settings.followPopups,
            captureMode: mode
        )))
        onStateChanged?()
    }

    func unsubscribeWindow(_ windowId: UInt64) {
        subscribedRootIds.remove(windowId)
        let wasMuted = mutedWindowIds.remove(windowId) != nil
        sendControl(.unsubscribeWindow(UnsubscribeWindow(windowId: windowId)))
        closeWindowLocally(windowId)
        if wasMuted && settings.audioEnabled {
            applyAudioSetting()
        }
        onStateChanged?()
    }

    func focusDesktopIfOpen() {
        if let existing = controllers[SyntheticWindow.primaryDesktop] {
            existing.present(owner: nil)
        }
    }

    func focusOrSubscribe(_ info: WindowInfo) {
        if let existing = controllers[info.windowId] {
            existing.present(owner: nil)
        } else {
            subscribeWindow(info)
        }
    }

    // MARK: - Window Layout Memory & Workspace Presets

    nonisolated static func layoutKey(for info: WindowInfo) -> String? {
        if info.windowId == SyntheticWindow.primaryDesktop {
            return "__desktop__"
        }
        guard info.kind != .popup else { return nil }
        let proc = info.processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return proc.isEmpty ? nil : "proc:\(proc)"
    }

    private func recordWindowLayout(for windowId: UInt64) {
        guard let wc = controllers[windowId],
              let key = Self.layoutKey(for: wc.info),
              let snap = wc.snapshotLayout() else { return }
        if settings.savedWindowLayouts[key] == snap {
            return
        }
        var s = settings
        s.savedWindowLayouts[key] = snap
        settings = s
    }

    @discardableResult
    func saveCurrentWorkspacePreset(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setBanner("请输入工作区预设名称", isError: true)
            onStateChanged?()
            return false
        }
        let openControllers = controllers.values
            .filter { $0.info.kind != .popup }
            .sorted { a, b in
                let aDesk = a.windowId == SyntheticWindow.primaryDesktop
                let bDesk = b.windowId == SyntheticWindow.primaryDesktop
                if aDesk != bDesk { return aDesk }
                if a.info.processName != b.info.processName {
                    return a.info.processName.localizedCaseInsensitiveCompare(b.info.processName) == .orderedAscending
                }
                return a.info.title.localizedCaseInsensitiveCompare(b.info.title) == .orderedAscending
            }
        var entries: [WorkspacePresetEntry] = []
        for wc in openControllers {
            guard let layout = wc.snapshotLayout() else { continue }
            let isDesktop = wc.windowId == SyntheticWindow.primaryDesktop
            entries.append(WorkspacePresetEntry(
                isDesktop: isDesktop,
                processName: isDesktop ? "" : wc.info.processName,
                titleHint: isDesktop ? "" : wc.info.title,
                layout: layout
            ))
        }
        guard !entries.isEmpty else {
            setBanner("当前没有正在投射的 Windows 窗口可保存为布局预设", isError: true)
            onStateChanged?()
            return false
        }
        var s = settings
        if let idx = s.workspacePresets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            s.workspacePresets[idx].name = name
            s.workspacePresets[idx].entries = entries
        } else {
            s.workspacePresets.append(WorkspacePreset(
                id: UUID().uuidString.lowercased(),
                name: name,
                entries: entries
            ))
        }
        settings = s
        setBanner("✓ 已保存工作区布局「\(name)」（共 \(entries.count) 个窗口）", isError: false)
        onStateChanged?()
        return true
    }

    func applyWorkspacePreset(id: String) {
        guard case .connected = connectionState else {
            setBanner("请先连接 Windows 主机再恢复工作区布局", isError: true)
            onStateChanged?()
            return
        }
        guard let preset = settings.workspacePresets.first(where: { $0.id == id }) else { return }
        var matchedIds = Set<UInt64>()
        var restoredCount = 0
        var missingCount = 0
        var audioMuteChanged = false

        for entry in preset.entries {
            if entry.isDesktop {
                if let existing = controllers[SyntheticWindow.primaryDesktop] {
                    existing.applySavedLayout(entry.layout)
                    existing.present(owner: nil)
                    if syncMuteState(windowId: SyntheticWindow.primaryDesktop, muted: entry.layout.isAudioMuted) {
                        audioMuteChanged = true
                    }
                } else {
                    pendingPresetLayouts["__desktop__"] = entry.layout
                    toggleDesktopView()
                }
                restoredCount += 1
                continue
            }
            let exact = availableWindows.first {
                !matchedIds.contains($0.windowId)
                    && $0.processName.caseInsensitiveCompare(entry.processName) == .orderedSame
                    && $0.title == entry.titleHint
            }
            let byProc = exact ?? availableWindows.first {
                !matchedIds.contains($0.windowId)
                    && !entry.processName.isEmpty
                    && $0.processName.caseInsensitiveCompare(entry.processName) == .orderedSame
            }
            guard let target = byProc else {
                missingCount += 1
                continue
            }
            matchedIds.insert(target.windowId)
            restoredCount += 1
            if let existing = controllers[target.windowId] {
                existing.applySavedLayout(entry.layout)
                existing.present(owner: nil)
                if syncMuteState(windowId: target.windowId, muted: entry.layout.isAudioMuted) {
                    audioMuteChanged = true
                }
            } else {
                if let key = Self.layoutKey(for: target) {
                    pendingPresetLayouts[key] = entry.layout
                }
                subscribeWindow(target)
            }
        }
        if audioMuteChanged && settings.audioEnabled {
            applyAudioSetting()
        }
        if missingCount > 0 {
            setBanner("已恢复工作区「\(preset.name)」：\(restoredCount) 个窗口就绪，\(missingCount) 个未在 Windows 运行", isError: false)
        } else {
            setBanner("✓ 已恢复工作区「\(preset.name)」（\(restoredCount) 个窗口）", isError: false)
        }
        onStateChanged?()
    }

    private func syncMuteState(windowId: UInt64, muted: Bool) -> Bool {
        if muted {
            return mutedWindowIds.insert(windowId).inserted
        } else {
            return mutedWindowIds.remove(windowId) != nil
        }
    }

    func deleteWorkspacePreset(id: String) {
        var s = settings
        guard let idx = s.workspacePresets.firstIndex(where: { $0.id == id }) else { return }
        let removed = s.workspacePresets.remove(at: idx)
        settings = s
        setBanner("已删除工作区布局「\(removed.name)」", isError: false)
        onStateChanged?()
    }

    func clearSavedWindowLayouts() {
        var s = settings
        let count = s.savedWindowLayouts.count
        s.savedWindowLayouts.removeAll()
        settings = s
        setBanner("已清除 \(count) 条已记忆的窗口位置记录", isError: false)
        onStateChanged?()
    }

    func requestKeyFrameForActiveWindow() {
        guard let keyWindow = NSApp.keyWindow,
              let wc = keyWindow.windowController as? RemoteWindowController else { return }
        sendControl(.requestKeyFrame(RequestKeyFrame(windowId: wc.windowId)))
    }

    func detachActiveWindow() {
        guard let keyWindow = NSApp.keyWindow,
              let wc = keyWindow.windowController as? RemoteWindowController else { return }
        unsubscribeWindow(wc.windowId)
    }

    func togglePointerLockForActiveWindow() {
        guard let keyWindow = NSApp.keyWindow,
              let wc = keyWindow.windowController as? RemoteWindowController else { return }
        wc.togglePointerLock()
    }

    func unlockAllPointers() {
        for (_, wc) in controllers {
            wc.unlockPointerIfNeeded()
        }
    }

    func sendControl(_ payload: ControlMessage.Payload) {
        connection?.send(payload)
    }

    // MARK: - Drag & Drop File Transfer (Mac -> Windows)

    nonisolated static func formatByteCount(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
        return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }

    private func showTransferToast(
        _ text: String,
        style: TransferToastStyle,
        windowId: UInt64? = nil,
        autoHideSeconds: TimeInterval? = nil
    ) {
        if let wid = windowId, let wc = controllers[wid] {
            if wc.info.kind == .popup, wc.info.ownerWindowId != 0, let owner = controllers[wc.info.ownerWindowId] {
                owner.showToast(text, style: style, autoHideSeconds: autoHideSeconds)
                return
            }
            wc.showToast(text, style: style, autoHideSeconds: autoHideSeconds)
            return
        }
        if let keyWC = NSApp.keyWindow?.windowController as? RemoteWindowController {
            keyWC.showToast(text, style: style, autoHideSeconds: autoHideSeconds)
            return
        }
        if let fallback = controllers.values.first(where: { $0.info.kind != .popup }) {
            fallback.showToast(text, style: style, autoHideSeconds: autoHideSeconds)
        }
    }

    func sendDroppedFiles(_ urls: [URL], toWindowId windowId: UInt64) {
        guard case .connected = connectionState, let conn = connection else { return }
        let maxBytes: UInt64 = 512 * 1024 * 1024
        let chunkSize = 128 * 1024

        Task { @MainActor [weak self] in
            guard let self else { return }
            let totalFiles = urls.count
            for (idx, rawURL) in urls.enumerated() {
                guard case .connected = self.connectionState else { break }
                let url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
                let name = url.lastPathComponent
                let batchPrefix = totalFiles > 1 ? "[\(idx + 1)/\(totalFiles)] " : ""
                var startedTransferId: UInt64?
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if values.isDirectory == true {
                        let msg = "\(batchPrefix)已跳过文件夹「\(name)」"
                        ClientLogger.shared.info("FileTransfer skip directory: \(url.path)")
                        self.setBanner(msg, isError: true)
                        self.showTransferToast(msg, style: .error, windowId: windowId, autoHideSeconds: 4.0)
                        self.onStateChanged?()
                        continue
                    }
                    let fileSize = UInt64(max(0, values.fileSize ?? 0))
                    guard fileSize <= maxBytes else {
                        let msg = "\(batchPrefix)文件「\(name)」超过 512 MiB 上限，已跳过"
                        ClientLogger.shared.error("FileTransfer rejected oversized file \(name) (\(fileSize) bytes)")
                        self.setBanner(msg, isError: true)
                        self.showTransferToast(msg, style: .error, windowId: windowId, autoHideSeconds: 5.0)
                        self.onStateChanged?()
                        continue
                    }
                    let transferId = self.nextTransferId
                    self.nextTransferId &+= 1
                    startedTransferId = transferId
                    self.activeTransferNames[transferId] = name
                    self.activeTransferTargetWindow[transferId] = windowId

                    let totalStr = Self.formatByteCount(fileSize)
                    let startMsg = "⬆ \(batchPrefix)正在发送「\(name)」(0% · 0 B / \(totalStr))…"
                    ClientLogger.shared.info(
                        "FileTransfer start id=\(transferId) name=\"\(name)\" bytes=\(fileSize) window=0x\(String(windowId, radix: 16))"
                    )
                    self.setBanner(startMsg, isError: false)
                    self.showTransferToast(startMsg, style: .progress, windowId: windowId, autoHideSeconds: nil)
                    self.onStateChanged?()

                    try await conn.sendBulkAsync(.fileTransferStart(FileTransferStart(
                        transferId: transferId,
                        targetWindowId: windowId,
                        fileName: name,
                        totalBytes: fileSize
                    )))

                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var offset: UInt64 = 0
                    var lastProgressUI = Date.distantPast
                    if fileSize == 0 {
                        try await conn.sendBulkAsync(.fileTransferChunk(FileTransferChunk(
                            transferId: transferId,
                            offset: 0,
                            data: Data(),
                            isLast: true
                        )))
                    } else {
                        while offset < fileSize {
                            guard case .connected = self.connectionState else { break }
                            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
                                break
                            }
                            let nextOffset = offset + UInt64(data.count)
                            let isLast = nextOffset >= fileSize
                            try await conn.sendBulkAsync(.fileTransferChunk(FileTransferChunk(
                                transferId: transferId,
                                offset: offset,
                                data: data,
                                isLast: isLast
                            )))
                            offset = nextOffset
                            let now = Date()
                            if isLast || now.timeIntervalSince(lastProgressUI) >= 0.12 {
                                lastProgressUI = now
                                let pct = min(100, Int((Double(offset) * 100.0) / Double(max(1, fileSize))))
                                let sentStr = Self.formatByteCount(offset)
                                let progressMsg = isLast
                                    ? "⬆ \(batchPrefix)「\(name)」已发送 100% (\(totalStr))，等待 Windows 保存…"
                                    : "⬆ \(batchPrefix)正在发送「\(name)」· \(pct)% (\(sentStr) / \(totalStr))"
                                self.setBanner(progressMsg, isError: false)
                                self.showTransferToast(progressMsg, style: .progress, windowId: windowId, autoHideSeconds: nil)
                                self.onStateChanged?()
                            }
                        }
                    }
                    ClientLogger.shared.info("FileTransfer sent all chunks id=\(transferId) bytes=\(offset)")
                } catch {
                    if let tid = startedTransferId {
                        self.activeTransferNames.removeValue(forKey: tid)
                        self.activeTransferTargetWindow.removeValue(forKey: tid)
                    }
                    let msg = "发送「\(name)」失败：\(error.localizedDescription)"
                    ClientLogger.shared.error("FileTransfer send error name=\"\(name)\": \(error.localizedDescription)")
                    self.setBanner(msg, isError: true)
                    self.showTransferToast("✕ \(msg)", style: .error, windowId: windowId, autoHideSeconds: 5.5)
                    self.onStateChanged?()
                }
            }
        }
    }

    func requestHostFileList(path: String) {
        guard case .connected = connectionState else {
            setBanner("请先连接 Windows 主机", isError: true)
            onStateChanged?()
            return
        }
        sendControl(.listHostFilesReq(ListHostFilesRequest(path: path)))
    }

    private static let maxIncomingPullBytes: UInt64 = 512 * 1024 * 1024

    nonisolated static func sanitizeIncomingFileName(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = last
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map { Character($0) }
        var name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            return "winbridge-file.bin"
        }
        if name.count > 180 {
            name = String(name.prefix(180))
        }
        return name
    }

    private static let autoPullClipboardLimitBytes: UInt64 = 20 * 1024 * 1024

    func toggleAutoPullClipboardFiles() {
        var s = settings
        s.autoPullClipboardFiles.toggle()
        settings = s
        setBanner(
            s.autoPullClipboardFiles
                ? "已开启：Windows 复制 ≤20 MB 文件时自动取回并写入 Mac 剪贴板（按 ⌘V 直接粘贴）"
                : "已关闭自动取回剪贴板文件（仍可按 ⌥⇧⌘V 手动取回）",
            isError: false
        )
        onStateChanged?()
    }

    func pullClipboardFilesToPasteboard(isAuto: Bool = false) {
        guard case .connected = connectionState else {
            if !isAuto {
                setBanner("请先连接 Windows 主机", isError: true)
                onStateChanged?()
            }
            return
        }
        let requestId = nextTransferId
        nextTransferId &+= 1
        pendingPullTargets[requestId] = PendingPullTarget(
            destinationURL: nil,
            copyToPasteboard: true,
            completion: nil
        )
        clipboardBatchFiles[requestId] = []
        let msg = isAuto ? "⬇ 正在自动同步 Windows 剪贴板文件…" : "⬇ 正在取回 Windows 剪贴板文件…"
        ClientLogger.shared.info("FilePull clipboard request id=\(requestId) auto=\(isAuto)")
        setBanner(msg, isError: false)
        showTransferToast(msg, style: .progress, autoHideSeconds: nil)
        onFilePullStatusChanged?(msg, false)
        onStateChanged?()
        sendControl(.filePullReq(FilePullRequest(requestId: requestId, path: "clipboard:")))
    }

    func pullHostFile(path: String, copyToPasteboard: Bool = true) {
        guard case .connected = connectionState else {
            setBanner("请先连接 Windows 主机", isError: true)
            onStateChanged?()
            return
        }
        let requestId = nextTransferId
        nextTransferId &+= 1
        pendingPullTargets[requestId] = PendingPullTarget(
            destinationURL: nil,
            copyToPasteboard: copyToPasteboard,
            completion: nil
        )
        if copyToPasteboard {
            clipboardBatchFiles[requestId] = []
        }
        let label: String
        if path == "clipboard:" {
            label = "剪贴板文件"
        } else {
            let tail = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            label = tail.isEmpty ? "文件" : tail
        }
        let msg = "⬇ 正在从 Windows 取回「\(label)」…"
        ClientLogger.shared.info("FilePull request id=\(requestId) path=\"\(path)\"")
        setBanner(msg, isError: false)
        showTransferToast(msg, style: .progress, autoHideSeconds: nil)
        onFilePullStatusChanged?(msg, false)
        onStateChanged?()
        sendControl(.filePullReq(FilePullRequest(requestId: requestId, path: path)))
    }

    /// Streams a remote file or folder (.zip) straight into a Finder-provided `NSFilePromiseProvider` destination URL.
    func pullHostFileToDestination(
        remotePath: String,
        destinationURL: URL,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard case .connected = connectionState else {
            let err = NSError(
                domain: "com.winbridge.client",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未连接到 Windows 主机"]
            )
            completion(err)
            return
        }
        let requestId = nextTransferId
        nextTransferId &+= 1
        pendingPullTargets[requestId] = PendingPullTarget(
            destinationURL: destinationURL,
            copyToPasteboard: false,
            completion: completion
        )
        let msg = "⬇ 正在拖出「\(destinationURL.lastPathComponent)」…"
        ClientLogger.shared.info(
            "FilePull promise request id=\(requestId) remote=\"\(remotePath)\" dest=\"\(destinationURL.path)\""
        )
        setBanner(msg, isError: false)
        showTransferToast(msg, style: .progress, autoHideSeconds: nil)
        onFilePullStatusChanged?(msg, false)
        onStateChanged?()
        sendControl(.filePullReq(FilePullRequest(requestId: requestId, path: remotePath)))
    }

    private func handleClipboardFilesNotice(_ notice: ClipboardFilesNotice) {
        guard !notice.files.isEmpty else { return }
        if notice.changeId != 0 && notice.changeId == lastClipboardFilesChangeId {
            return
        }
        lastClipboardFilesChangeId = notice.changeId
        lastHostClipboardNotice = notice

        let firstName = notice.files[0].name
        let summary = notice.files.count == 1
            ? firstName
            : "\(firstName) 等 \(notice.files.count) 个文件"
        let sizeStr = Self.formatByteCount(notice.totalBytes)
        ClientLogger.shared.info(
            "ClipboardFilesNotice seq=\(notice.changeId) count=\(notice.files.count) bytes=\(notice.totalBytes) skipped=\(notice.skippedCount)"
        )

        if settings.syncClipboard
            && settings.autoPullClipboardFiles
            && notice.totalBytes <= Self.autoPullClipboardLimitBytes {
            pullClipboardFilesToPasteboard(isAuto: true)
        } else {
            let msg = "📋 Windows 已复制「\(summary)」(\(sizeStr)) — 按 ⌥⇧⌘V 立即取回到 Mac 剪贴板"
            setBanner(msg, isError: false)
            showTransferToast(msg, style: .progress, autoHideSeconds: 6.5)
            onFilePullStatusChanged?(msg, false)
            onStateChanged?()
        }
    }

    private func macDropDirectory() -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("WinBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func beginIncomingPull(_ start: FileTransferStart) {
        let name = Self.sanitizeIncomingFileName(start.fileName)
        let pending: PendingPullTarget?
        if start.requestId != 0, let entry = pendingPullTargets[start.requestId] {
            pending = entry
            // Single-file drag-out promises consume their target immediately; clipboard batches may emit multiple files.
            if entry.destinationURL != nil {
                pendingPullTargets.removeValue(forKey: start.requestId)
            }
        } else {
            pending = nil
        }

        guard start.totalBytes <= Self.maxIncomingPullBytes else {
            let msg = "取回「\(name)」失败：文件超过 512 MiB 上限"
            pending?.completion?(NSError(domain: "com.winbridge.client", code: 2, userInfo: [NSLocalizedDescriptionKey: msg]))
            setBanner(msg, isError: true)
            showTransferToast("✕ \(msg)", style: .error, autoHideSeconds: 5.5)
            onFilePullStatusChanged?(msg, true)
            onStateChanged?()
            return
        }
        if let existing = incomingPulls.removeValue(forKey: start.transferId) {
            try? existing.handle.close()
            try? FileManager.default.removeItem(at: existing.partialURL)
            existing.completion?(ConnectionError.connectionClosed)
        }

        let dest: URL
        let partialDir: URL
        let isCustomDest: Bool
        if let promisedURL = pending?.destinationURL {
            dest = promisedURL
            partialDir = promisedURL.deletingLastPathComponent()
            isCustomDest = true
        } else {
            let dir = macDropDirectory()
            var candidateDest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidateDest.path) {
                let stem = candidateDest.deletingPathExtension().lastPathComponent
                let ext = candidateDest.pathExtension
                for n in 1..<10_000 {
                    let candidateName = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                    let candidate = dir.appendingPathComponent(candidateName)
                    if !FileManager.default.fileExists(atPath: candidate.path) {
                        candidateDest = candidate
                        break
                    }
                }
            }
            dest = candidateDest
            partialDir = dir
            isCustomDest = false
        }

        let partial = partialDir.appendingPathComponent(".\(dest.lastPathComponent).\(start.transferId).winbridge.part")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else {
            let msg = "无法写入 \(partial.path)"
            pending?.completion?(NSError(domain: "com.winbridge.client", code: 3, userInfo: [NSLocalizedDescriptionKey: msg]))
            setBanner(msg, isError: true)
            showTransferToast("✕ \(msg)", style: .error, autoHideSeconds: 5.5)
            onFilePullStatusChanged?(msg, true)
            onStateChanged?()
            return
        }
        incomingPulls[start.transferId] = IncomingPull(
            requestId: start.requestId,
            finalURL: dest,
            partialURL: partial,
            handle: handle,
            expected: start.totalBytes,
            customDestination: isCustomDest,
            copyToPasteboard: pending?.copyToPasteboard ?? false,
            completion: pending?.completion,
            received: 0,
            lastProgressToastAt: .distantPast
        )
        let totalStr = Self.formatByteCount(start.totalBytes)
        ClientLogger.shared.info(
            "FilePull start id=\(start.transferId) req=\(start.requestId) name=\"\(dest.lastPathComponent)\" bytes=\(start.totalBytes) customDest=\(isCustomDest)"
        )
        let msg = "⬇ 正在从 Windows 取回「\(dest.lastPathComponent)」(0% · 0 B / \(totalStr))…"
        setBanner(msg, isError: false)
        showTransferToast(msg, style: .progress, autoHideSeconds: nil)
        onFilePullStatusChanged?(msg, false)
        onStateChanged?()
    }

    private func appendIncomingChunk(_ chunk: FileTransferChunk) {
        guard var pull = incomingPulls[chunk.transferId] else { return }
        if chunk.offset != pull.received {
            finishIncoming(chunk.transferId, success: false, message: "分块偏移不连续（预期 \(pull.received)，实际 \(chunk.offset)）")
            return
        }
        let nextTotal = pull.received + UInt64(chunk.data.count)
        if nextTotal > pull.expected || nextTotal > Self.maxIncomingPullBytes {
            finishIncoming(chunk.transferId, success: false, message: "收到超限分块数据")
            return
        }
        if !chunk.data.isEmpty {
            do {
                try pull.handle.write(contentsOf: chunk.data)
            } catch {
                finishIncoming(chunk.transferId, success: false, message: "写入磁盘失败：\(error.localizedDescription)")
                return
            }
            pull.received = nextTotal
        }
        let now = Date()
        if chunk.isLast || now.timeIntervalSince(pull.lastProgressToastAt) >= 0.15 {
            pull.lastProgressToastAt = now
            let pct = pull.expected == 0 ? 100 : min(100, Int((Double(pull.received) * 100.0) / Double(pull.expected)))
            let msg = "⬇ 正在取回「\(pull.finalURL.lastPathComponent)」· \(pct)% (\(Self.formatByteCount(pull.received)) / \(Self.formatByteCount(pull.expected)))"
            setBanner(msg, isError: false)
            showTransferToast(msg, style: .progress, autoHideSeconds: nil)
            onFilePullStatusChanged?(msg, false)
        }
        incomingPulls[chunk.transferId] = pull
    }

    private func finishIncoming(_ id: UInt64, success: Bool, message: String) {
        guard let pull = incomingPulls.removeValue(forKey: id) else { return }
        try? pull.handle.close()
        let name = pull.finalURL.lastPathComponent
        let complete = success && pull.received == pull.expected
        if complete {
            do {
                if FileManager.default.fileExists(atPath: pull.finalURL.path) {
                    try FileManager.default.removeItem(at: pull.finalURL)
                }
                try FileManager.default.moveItem(at: pull.partialURL, to: pull.finalURL)
                pull.completion?(nil)
                ClientLogger.shared.info("FilePull done id=\(id) path=\"\(pull.finalURL.path)\" bytes=\(pull.received)")

                let msg: String
                if pull.customDestination {
                    let folder = pull.finalURL.deletingLastPathComponent().lastPathComponent
                    msg = "✓ 已拖出保存「\(name)」到 \(folder)"
                } else if pull.copyToPasteboard {
                    var batch = clipboardBatchFiles[pull.requestId] ?? []
                    batch.append(pull.finalURL)
                    clipboardBatchFiles[pull.requestId] = batch
                    clipboardMonitor.applyRemoteFiles(batch)
                    let batchNote = batch.count > 1 ? "（共 \(batch.count) 个文件）" : ""
                    msg = "✓ 「\(name)」已取回并写入 Mac 剪贴板\(batchNote)，按 ⌘V 可直接粘贴"
                } else {
                    msg = "✓ 文件「\(name)」已取回到 Mac：\(pull.finalURL.path)"
                }
                setBanner(msg, isError: false)
                showTransferToast(msg, style: .success, autoHideSeconds: 5.5)
                onFilePullStatusChanged?(msg, false)
            } catch {
                try? FileManager.default.removeItem(at: pull.partialURL)
                pull.completion?(error)
                let msg = "保存「\(name)」失败：\(error.localizedDescription)"
                ClientLogger.shared.error("FilePull save failed id=\(id): \(error.localizedDescription)")
                setBanner(msg, isError: true)
                showTransferToast("✕ \(msg)", style: .error, autoHideSeconds: 5.5)
                onFilePullStatusChanged?(msg, true)
            }
        } else {
            try? FileManager.default.removeItem(at: pull.partialURL)
            let why = message.isEmpty ? "传输不完整" : message
            let err = NSError(domain: "com.winbridge.client", code: 4, userInfo: [NSLocalizedDescriptionKey: why])
            pull.completion?(err)
            let msg = "取回「\(name)」失败：\(why)"
            ClientLogger.shared.error("FilePull failed id=\(id) name=\"\(name)\": \(why)")
            setBanner(msg, isError: true)
            showTransferToast("✕ \(msg)", style: .error, autoHideSeconds: 5.5)
            onFilePullStatusChanged?(msg, true)
        }
        onStateChanged?()
    }

    // MARK: - Inbound Control Dispatch

    private func handleControlMessage(_ msg: ControlMessage) {
        switch msg.payload {
        case .listWindowsRes(let res):
            availableWindows = res.windows
            restoreWindowsIfPending(from: res.windows)
            onStateChanged?()

        case .listAppsRes(let res):
            availableApps = res.apps
            onStateChanged?()

        case .launchAppRes(let res):
            if res.started {
                let name = availableApps.first(where: { $0.appId == res.appId })?.name ?? "应用"
                setBanner("已向 Windows 发送启动「\(name)」，正在等待主窗口出现…", isError: false)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    self?.refreshWindowList()
                }
            } else {
                setBanner("启动失败：\(res.message)", isError: true)
            }
            onStateChanged?()

        case .windowUpdated(let update):
            handleWindowUpdated(update)

        case .windowClosed(let closed):
            ClientLogger.shared.info("WindowClosed 0x\(String(closed.windowId, radix: 16))")
            subscribedRootIds.remove(closed.windowId)
            mutedWindowIds.remove(closed.windowId)
            closeWindowLocally(closed.windowId)
            onStateChanged?()

        case .cursorShape(let shape):
            controllers[shape.windowId]?.applyCursor(shape)

        case .clipboardSync(let sync):
            clipboardMonitor.applyRemote(sync)

        case .clipboardFilesNotice(let notice):
            handleClipboardFilesNotice(notice)

        case .hostNotification(let note):
            handleHostNotification(note)

        case .listHostFilesRes(let res):
            onHostFilesListed?(res)
            if !res.error.isEmpty {
                setBanner("列出 Windows 文件失败：\(res.error)", isError: true)
                onFilePullStatusChanged?("列出目录失败：\(res.error)", true)
                onStateChanged?()
            }

        case .fileTransferStart(let start):
            if start.direction == FileTransferStart.directionToClient {
                beginIncomingPull(start)
            }

        case .fileTransferChunk(let chunk):
            if incomingPulls[chunk.transferId] != nil {
                appendIncomingChunk(chunk)
            }

        case .fileTransferRes(let res):
            if incomingPulls[res.transferId] != nil {
                finishIncoming(res.transferId, success: res.success, message: res.message)
                break
            }
            if let pending = pendingPullTargets.removeValue(forKey: res.transferId) {
                clipboardBatchFiles.removeValue(forKey: res.transferId)
                let why = res.message.isEmpty ? "取回文件失败" : res.message
                pending.completion?(NSError(domain: "com.winbridge.client", code: 5, userInfo: [NSLocalizedDescriptionKey: why]))
                ClientLogger.shared.error("FilePull rejected id=\(res.transferId): \(why)")
                setBanner("取回文件失败：\(why)", isError: true)
                showTransferToast("✕ 取回文件失败：\(why)", style: .error, autoHideSeconds: 5.5)
                onFilePullStatusChanged?("取回失败：\(why)", true)
                onStateChanged?()
                break
            }
            let targetWin = activeTransferTargetWindow.removeValue(forKey: res.transferId)
            if let name = activeTransferNames.removeValue(forKey: res.transferId) {
                if res.success {
                    let bannerMsg = "✓ 文件「\(name)」已保存到 Windows：\(res.savedPath)（已写入 Windows 剪贴板，按 ⌘V 可直接粘贴）"
                    let toastMsg = "✓ 已发送到 Windows：\(res.savedPath)\n已自动复制到 Windows 剪贴板，按 ⌘V 可直接粘贴"
                    ClientLogger.shared.info("FileTransfer done id=\(res.transferId) saved=\"\(res.savedPath)\"")
                    setBanner(bannerMsg, isError: false)
                    showTransferToast(toastMsg, style: .success, windowId: targetWin, autoHideSeconds: 5.5)
                } else {
                    let msg = "文件「\(name)」传输失败：\(res.message)"
                    ClientLogger.shared.error("FileTransfer failed id=\(res.transferId) name=\"\(name)\": \(res.message)")
                    setBanner(msg, isError: true)
                    showTransferToast("✕ \(msg)", style: .error, windowId: targetWin, autoHideSeconds: 5.5)
                }
                onStateChanged?()
            } else if !res.success {
                let msg = "文件传输失败：\(res.message)"
                ClientLogger.shared.error("FileTransfer error id=\(res.transferId): \(res.message)")
                setBanner(msg, isError: true)
                showTransferToast("✕ \(msg)", style: .error, windowId: targetWin, autoHideSeconds: 5.5)
                onStateChanged?()
            }

        case .hostError(let err):
            handleHostError(err)

        default:
            break
        }
    }

    private func handleWindowUpdated(_ update: WindowUpdated) {
        guard let info = update.window else { return }
        let ownerController = info.ownerWindowId != 0 ? controllers[info.ownerWindowId] : nil

        if let existing = controllers[info.windowId] {
            existing.applyUpdate(update, owner: ownerController)
            return
        }

        let wc = RemoteWindowController(
            info: info,
            owner: ownerController,
            syncWindowResize: { [weak self] in self?.settings.syncWindowResize ?? false }
        )
        let procName = info.processName
        wc.cmdMapsToCtrl = { [weak self] in self?.settings.cmdMapsToCtrl ?? true }
        wc.mouseSensitivity = { [weak self] in self?.mouseSensitivity(forProcess: procName) ?? 1.0 }
        wc.suppressInactiveHover = { [weak self] in self?.settings.suppressInactiveHover ?? false }
        wc.shortcuts = { [weak self] in self?.settings.shortcuts ?? .defaults }
        wc.showPerformanceHud = { [weak self] in self?.settings.showPerformanceHud ?? false }
        wc.currentRttMs = { [weak self] in self?.rttMs }
        wc.onSendControl = { [weak self] payload in self?.sendControl(payload) }
        wc.onDetachRequested = { [weak self] id in self?.unsubscribeWindow(id) }
        wc.onOwnerMovedOrResized = { [weak self] ownerId in self?.repositionOwnedPopups(for: ownerId) }
        wc.onRequestQuit = { NSApp.terminate(nil) }
        wc.onOpenManager = { [weak self] in self?.onOpenManager?() }
        wc.onToggleHud = { [weak self] in self?.togglePerformanceHud() }
        wc.onToggleMuteWindow = { [weak self] id in self?.toggleMute(windowId: id) }
        wc.onPinOnTopChanged = { [weak self] in self?.onStateChanged?() }
        wc.onLayoutChanged = { [weak self] id in self?.recordWindowLayout(for: id) }
        wc.onPullClipboardFiles = { [weak self] in self?.pullClipboardFilesToPasteboard(isAuto: false) }
        wc.onFilesDropped = { [weak self] winId, urls in self?.sendDroppedFiles(urls, toWindowId: winId) }

        controllers[info.windowId] = wc
        ClientLogger.shared.info("Opened window 0x\(String(info.windowId, radix: 16)) kind=\(info.kind) \(info.width)x\(info.height) title=\"\(info.title)\"")
        if info.kind == .normal {
            subscribedRootIds.insert(info.windowId)
            let procKey = info.processName.lowercased()
            if !procKey.isEmpty, settings.processVideoProfiles[procKey] != nil {
                pushVideoConfig(windowId: info.windowId)
            }
        }
        wc.present(owner: ownerController)
        if let layoutKey = Self.layoutKey(for: info),
           let savedLayout = pendingPresetLayouts.removeValue(forKey: layoutKey) ?? settings.savedWindowLayouts[layoutKey] {
            wc.applySavedLayout(savedLayout)
            if savedLayout.isAudioMuted && !mutedWindowIds.contains(info.windowId) {
                mutedWindowIds.insert(info.windowId)
                if settings.audioEnabled {
                    applyAudioSetting()
                }
            }
        }
        wc.updateHudVisibility()
        if info.kind == .normal && isAutoGameLockEnabled(forProcess: info.processName) {
            wc.setPointerLock(true)
        }
        onStateChanged?()
    }

    private func repositionOwnedPopups(for ownerId: UInt64) {
        guard let owner = controllers[ownerId] else { return }
        for (_, child) in controllers where child.info.ownerWindowId == ownerId && child.info.kind == .popup {
            child.repositionRelative(to: owner)
        }
    }

    private func closeWindowLocally(_ windowId: UInt64) {
        let ownedIds = controllers.values
            .filter { $0.info.ownerWindowId == windowId && $0.info.kind == .popup }
            .map(\.windowId)
        for childId in ownedIds {
            controllers.removeValue(forKey: childId)?.forceCloseLocally()
        }
        controllers.removeValue(forKey: windowId)?.forceCloseLocally()
    }

    private func handleHostError(_ err: HostError) {
        ClientLogger.shared.error("HostError window=0x\(String(err.windowId, radix: 16)) code=\(err.code) msg=\(err.message)")
        let prefix: String
        switch err.code {
        case .displayDisconnected:
            prefix = "[显示器断开] "
        case .capturePausedMinimized:
            prefix = "[窗口已最小化] "
        case .accessDeniedElevated:
            prefix = "[管理员权限拦截] "
        case .windowNotFound:
            prefix = "[窗口不可用] "
            subscribedRootIds.remove(err.windowId)
            mutedWindowIds.remove(err.windowId)
            closeWindowLocally(err.windowId)
        case .captureFailed:
            prefix = "[采集失败] "
        case .encoderError:
            prefix = "[编码错误] "
        case .unspecified:
            prefix = "[提示] "
        }
        setBanner(prefix + err.message, isError: true)
        onStateChanged?()
    }

    func setBanner(_ message: String, isError: Bool) {
        lastBannerMessage = message
        lastBannerIsError = isError
    }
}
