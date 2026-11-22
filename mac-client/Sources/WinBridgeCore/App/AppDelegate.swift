import AppKit
import Foundation

@MainActor
public enum WinBridgeAppLauncher {
    private static var retainedDelegate: AppDelegate?

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private let globalHotKey = GlobalHotKey()
    private var managerController: ManagerWindowController?
    private var filePullController: FilePullWindowController?
    private var quickLauncherController: QuickLauncherWindowController?
    private var shortcutsController: ShortcutsWindowController?
    private var statusItem: NSStatusItem?
    private var windowMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        let manager = ManagerWindowController(state: state)
        self.managerController = manager
        self.quickLauncherController = QuickLauncherWindowController(state: state)

        state.onStateChanged = { [weak self] in
            self?.managerController?.refreshUI()
            self?.quickLauncherController?.refreshResults()
            self?.rebuildStatusMenu()
            self?.rebuildWindowMenu()
        }
        state.onOpenManager = { [weak self] in
            self?.showManager()
        }
        state.onShortcutsChanged = { [weak self] in
            self?.registerConfiguredHotKey()
            self?.rebuildWindowMenu()
            self?.rebuildStatusMenu()
        }
        registerConfiguredHotKey()
        state.startDiscovery()

        showManager()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showManager()
        }
        return true
    }

    func applicationWillResignActive(_ notification: Notification) {
        state.unlockAllPointers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKey.unregister()
        state.stopDiscovery()
        state.unlockAllPointers()
        state.disconnect()
    }

    private func registerConfiguredHotKey() {
        globalHotKey.register(shortcut: state.settings.shortcuts.quickLauncher) { [weak self] in
            self?.toggleQuickLauncherAction()
        }
    }

    @objc private func showShortcutsAction() {
        if shortcutsController == nil {
            shortcutsController = ShortcutsWindowController(state: state)
        }
        shortcutsController?.show()
    }

    @objc private func toggleQuickLauncherAction() {
        if quickLauncherController == nil {
            quickLauncherController = QuickLauncherWindowController(state: state)
        }
        quickLauncherController?.toggle()
    }

    @objc func showManager() {
        managerController?.showWindow(nil)
        managerController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshWindowsAction() {
        state.refreshWindowList()
    }

    @objc private func requestKeyframeAction() {
        state.requestKeyFrameForActiveWindow()
    }

    @objc private func showFilePullAction() {
        if filePullController == nil {
            filePullController = FilePullWindowController(state: state)
        }
        filePullController?.show()
    }

    @objc private func detachActiveWindowAction() {
        state.detachActiveWindow()
    }

    @objc private func togglePointerLockAction() {
        state.togglePointerLockForActiveWindow()
    }

    @objc private func toggleAutoGameLockAction() {
        state.toggleAutoGameLockForActiveWindow()
    }

    @objc private func toggleAlwaysShowLocalCursorAction() {
        state.toggleAlwaysShowLocalCursorForActiveWindow()
    }

    @objc private func toggleHudAction() {
        state.togglePerformanceHud()
    }

    @objc private func togglePinOnTopAction() {
        state.togglePinOnTopForActiveWindow()
    }

    @objc private func toggleMuteWindowAction() {
        state.toggleMuteForActiveWindow()
    }

    @objc private func wakeAndConnectAction() {
        state.wakeAndConnect()
    }

    @objc private func setTransportPreferenceAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pref = TransportPreference(rawValue: raw) else { return }
        state.setTransportPreference(pref)
    }

    @objc private func toggleAutoWanOptimizeAction() {
        state.toggleAutoWanOptimize()
    }

    @objc private func toggleForwardNotificationsAction() {
        state.toggleForwardNotifications()
    }

    @objc private func saveWorkspacePresetAction() {
        let alert = NSAlert()
        alert.messageText = "保存当前工作区布局"
        alert.informativeText = "将当前所有已投射 Windows 窗口的位置、尺寸、置顶与静音状态保存为一键预设："
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "例如：开发模式 / 挂机双开 / 办公"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            state.saveCurrentWorkspacePreset(named: input.stringValue)
        }
    }

    @objc private func applyWorkspacePresetAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.applyWorkspacePreset(id: id)
    }

    @objc private func deleteWorkspacePresetAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.deleteWorkspacePreset(id: id)
    }

    @objc private func clearSavedWindowLayoutsAction() {
        state.clearSavedWindowLayouts()
    }

    @objc private func disconnectAction() {
        state.disconnect()
    }

    @objc private func resetTrustAction() {
        state.resetTrustedFingerprintForCurrentHost()
    }

    @objc private func toggleAudioAction() {
        state.toggleAudioEnabled()
    }

    @objc private func toggleAudioProcessOnlyAction() {
        state.toggleAudioProcessOnly()
    }

    @objc private func pullClipboardFilesAction() {
        state.pullClipboardFilesToPasteboard(isAuto: false)
    }

    @objc private func toggleAutoPullClipboardFilesAction() {
        state.toggleAutoPullClipboardFiles()
    }

    @objc private func setVideoProfileAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = VideoProfilePreference(rawValue: raw) else { return }
        state.setVideoProfile(profile)
    }

    @objc private func setProcessVideoProfileAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = VideoProfilePreference(rawValue: raw) else { return }
        state.setVideoProfileForActiveProcess(profile)
    }

    @objc private func toggleAdaptiveBitrateAction() {
        state.toggleAdaptiveBitrate()
    }

    @objc private func toggleDesktopAction() {
        state.toggleDesktopView()
    }

    @objc private func launchPinnedAppAction(_ sender: NSMenuItem) {
        guard let appId = sender.representedObject as? String,
              let app = state.availableApps.first(where: { $0.appId == appId }) else { return }
        state.launchApp(app)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "打开 WinBridge 管理窗口", action: #selector(showManager), keyEquivalent: ",")
        appMenu.addItem(withTitle: "快捷键设置…", action: #selector(showShortcutsAction), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 WinBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Edit menu (enables Cmd+C/V/A in Manager IP/Token fields; RemoteWindowView intercepts when focused)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "窗口")
        winMenu.delegate = self
        windowMenu = winMenu
        rebuildWindowMenu()
        winItem.submenu = winMenu
        mainMenu.addItem(winItem)

        NSApp.mainMenu = mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === windowMenu {
            rebuildWindowMenu()
        }
    }

    private func rebuildWindowMenu() {
        guard let winMenu = windowMenu else { return }
        let sc = state.settings.shortcuts
        winMenu.removeAllItems()
        let launcherItem = NSMenuItem(
            title: "快速启动 / 切换窗口 (\(sc.quickLauncher.displayString))",
            action: #selector(toggleQuickLauncherAction),
            keyEquivalent: ""
        )
        winMenu.addItem(launcherItem)
        winMenu.addItem(withTitle: "刷新 Windows 窗口列表", action: #selector(refreshWindowsAction), keyEquivalent: "")
        let lockItem = NSMenuItem(
            title: "锁定 / 解锁游戏鼠标 (3D 相对视角)",
            action: #selector(togglePointerLockAction),
            keyEquivalent: sc.toggleGameLock.menuKeyEquivalent
        )
        lockItem.keyEquivalentModifierMask = sc.toggleGameLock.modifierFlags
        winMenu.addItem(lockItem)
        winMenu.addItem(withTitle: "记住当前游戏自动开启鼠标锁定", action: #selector(toggleAutoGameLockAction), keyEquivalent: "")
        let forceCursorItem = NSMenuItem(
            title: "始终显示本地鼠标指针（游戏光标消失时开启）",
            action: #selector(toggleAlwaysShowLocalCursorAction),
            keyEquivalent: ""
        )
        forceCursorItem.state = state.isActiveWindowAlwaysShowingLocalCursor() ? .on : .off
        winMenu.addItem(forceCursorItem)
        let hudItem = NSMenuItem(
            title: "显示 / 隐藏性能 HUD",
            action: #selector(toggleHudAction),
            keyEquivalent: sc.toggleHud.menuKeyEquivalent
        )
        hudItem.keyEquivalentModifierMask = sc.toggleHud.modifierFlags
        winMenu.addItem(hudItem)
        let pinItem = NSMenuItem(
            title: "窗口置顶（当前桌面）",
            action: #selector(togglePinOnTopAction),
            keyEquivalent: sc.pinOnTop.menuKeyEquivalent
        )
        pinItem.keyEquivalentModifierMask = sc.pinOnTop.modifierFlags
        pinItem.state = state.isActiveWindowPinnedOnTop() ? .on : .off
        winMenu.addItem(pinItem)
        let muteItem = NSMenuItem(
            title: "静音当前窗口音频",
            action: #selector(toggleMuteWindowAction),
            keyEquivalent: sc.muteWindow.menuKeyEquivalent
        )
        muteItem.keyEquivalentModifierMask = sc.muteWindow.modifierFlags
        muteItem.state = state.isActiveWindowMuted() ? .on : .off
        winMenu.addItem(muteItem)
        winMenu.addItem(withTitle: "刷新当前窗口关键帧 (IDR)", action: #selector(requestKeyframeAction), keyEquivalent: "")
        winMenu.addItem(withTitle: "从 Windows 取回文件…", action: #selector(showFilePullAction), keyEquivalent: "")
        let pullClipItem = NSMenuItem(
            title: "取回 Windows 剪贴板文件 (写入 Mac ⌘V)",
            action: #selector(pullClipboardFilesAction),
            keyEquivalent: sc.pullClipboardFiles.menuKeyEquivalent
        )
        pullClipItem.keyEquivalentModifierMask = sc.pullClipboardFiles.modifierFlags
        winMenu.addItem(pullClipItem)
        let autoPullItem = NSMenuItem(
            title: "剪贴板文件自动取回 (≤20 MB)",
            action: #selector(toggleAutoPullClipboardFilesAction),
            keyEquivalent: ""
        )
        autoPullItem.state = state.settings.autoPullClipboardFiles ? .on : .off
        winMenu.addItem(autoPullItem)
        let notifyWinItem = NSMenuItem(
            title: "转发 Windows 通知到 macOS 通知中心",
            action: #selector(toggleForwardNotificationsAction),
            keyEquivalent: ""
        )
        notifyWinItem.state = state.settings.forwardNotifications ? .on : .off
        winMenu.addItem(notifyWinItem)
        appendVideoQualityItems(to: winMenu, includeProcess: true)
        winMenu.addItem(.separator())
        winMenu.addItem(makeWorkspacePresetsMenuItem())
        winMenu.addItem(withTitle: "快捷键设置…", action: #selector(showShortcutsAction), keyEquivalent: "")
        let transportItem = NSMenuItem(title: "传输通道", action: nil, keyEquivalent: "")
        let transportMenu = NSMenu()
        for pref in TransportPreference.allCases {
            let item = NSMenuItem(
                title: pref.title,
                action: #selector(setTransportPreferenceAction(_:)),
                keyEquivalent: ""
            )
            item.representedObject = pref.rawValue
            item.state = state.settings.transportPreference == pref ? .on : .off
            transportMenu.addItem(item)
        }
        transportMenu.addItem(.separator())
        let wanItem = NSMenuItem(
            title: "外网自动弱网优化 (备用地址 / RTT≥30ms)",
            action: #selector(toggleAutoWanOptimizeAction),
            keyEquivalent: ""
        )
        wanItem.state = state.settings.autoWanOptimize ? .on : .off
        transportMenu.addItem(wanItem)
        transportItem.submenu = transportMenu
        winMenu.addItem(transportItem)
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "脱离当前远端窗口", action: #selector(detachActiveWindowAction), keyEquivalent: "")
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: "重置当前主机 TLS 证书信任", action: #selector(resetTrustAction), keyEquivalent: "")
        winMenu.addItem(withTitle: "断开连接", action: #selector(disconnectAction), keyEquivalent: "")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "WinBridge")
            button.toolTip = "WinBridge"
        }
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        switch state.connectionState {
        case .disconnected:
            menu.addItem(withTitle: "状态：未连接", action: nil, keyEquivalent: "")
        case .connecting:
            menu.addItem(withTitle: "状态：连接中…", action: nil, keyEquivalent: "")
        case .connected(let host, let codec):
            let transport = state.activeTransport.map { " · \($0.rawValue)" } ?? ""
            let fb = state.connectedViaFallback ? " · 备用" : ""
            menu.addItem(withTitle: "已连接：\(host) (\(codec.displayName)\(transport)\(fb))", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let launcherStatusItem = NSMenuItem(
            title: "快速启动 / 切换窗口 (\(state.settings.shortcuts.quickLauncher.displayString))",
            action: #selector(toggleQuickLauncherAction),
            keyEquivalent: ""
        )
        launcherStatusItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(launcherStatusItem)
        menu.addItem(withTitle: "打开管理窗口…", action: #selector(showManager), keyEquivalent: "")
        if state.connectionState == .disconnected,
           WakeOnLan.normalizeMac(state.settings.macAddress) != nil {
            let wolItem = NSMenuItem(
                title: "唤醒并连接当前主机 (WoL)",
                action: #selector(wakeAndConnectAction),
                keyEquivalent: ""
            )
            wolItem.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
            menu.addItem(wolItem)
        }
        if case .connected = state.connectionState {
            let desktopItem = NSMenuItem(
                title: state.isDesktopOpen ? "关闭 Windows 完整桌面" : "查看 Windows 完整桌面",
                action: #selector(toggleDesktopAction),
                keyEquivalent: ""
            )
            desktopItem.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            menu.addItem(desktopItem)

            let audioItem = NSMenuItem(title: "开启 Windows 音频", action: #selector(toggleAudioAction), keyEquivalent: "")
            audioItem.state = state.settings.audioEnabled ? .on : .off
            menu.addItem(audioItem)
            let processAudio = NSMenuItem(
                title: "只采集已投射进程",
                action: #selector(toggleAudioProcessOnlyAction),
                keyEquivalent: ""
            )
            processAudio.state = state.settings.audioProcessOnly ? .on : .off
            menu.addItem(processAudio)
            menu.addItem(withTitle: "从 Windows 取回文件…", action: #selector(showFilePullAction), keyEquivalent: "")
            menu.addItem(withTitle: "取回 Windows 剪贴板文件 (⌥⇧⌘V)", action: #selector(pullClipboardFilesAction), keyEquivalent: "")
            let autoPullStatus = NSMenuItem(
                title: "剪贴板文件自动取回 (≤20 MB)",
                action: #selector(toggleAutoPullClipboardFilesAction),
                keyEquivalent: ""
            )
            autoPullStatus.state = state.settings.autoPullClipboardFiles ? .on : .off
            menu.addItem(autoPullStatus)
            let notifyStatusItem = NSMenuItem(
                title: "转发 Windows 通知",
                action: #selector(toggleForwardNotificationsAction),
                keyEquivalent: ""
            )
            notifyStatusItem.state = state.settings.forwardNotifications ? .on : .off
            menu.addItem(notifyStatusItem)
            appendVideoQualityItems(to: menu, includeProcess: true)
            menu.addItem(.separator())
            menu.addItem(makeWorkspacePresetsMenuItem())

            let pinned = state.pinnedApps
            if !pinned.isEmpty {
                menu.addItem(.separator())
                let header = NSMenuItem(title: "快速启动 Windows 应用", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for app in pinned {
                    let item = NSMenuItem(title: app.name, action: #selector(launchPinnedAppAction(_:)), keyEquivalent: "")
                    item.representedObject = app.appId
                    if !app.iconPng.isEmpty, let img = NSImage(data: app.iconPng) {
                        img.size = NSSize(width: 16, height: 16)
                        item.image = img
                    }
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
            menu.addItem(withTitle: "刷新 Windows 窗口列表", action: #selector(refreshWindowsAction), keyEquivalent: "")
            menu.addItem(withTitle: "断开连接", action: #selector(disconnectAction), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 WinBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem?.menu = menu
    }

    private func appendVideoQualityItems(to menu: NSMenu, includeProcess: Bool) {
        menu.addItem(.separator())
        let header = NSMenuItem(title: "画质", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for profile in VideoProfilePreference.allCases {
            let item = NSMenuItem(title: profile.title, action: #selector(setVideoProfileAction(_:)), keyEquivalent: "")
            item.representedObject = profile.rawValue
            item.state = state.settings.videoProfile == profile ? .on : .off
            menu.addItem(item)
        }
        let adaptive = NSMenuItem(title: "自适应码率", action: #selector(toggleAdaptiveBitrateAction), keyEquivalent: "")
        adaptive.state = state.settings.adaptiveBitrate ? .on : .off
        menu.addItem(adaptive)
        if includeProcess {
            let sub = NSMenuItem(title: "仅当前进程使用…", action: nil, keyEquivalent: "")
            let subMenu = NSMenu()
            for profile in VideoProfilePreference.allCases {
                let item = NSMenuItem(
                    title: profile.title,
                    action: #selector(setProcessVideoProfileAction(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = profile.rawValue
                subMenu.addItem(item)
            }
            sub.submenu = subMenu
            menu.addItem(sub)
        }
    }

    private func makeWorkspacePresetsMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "工作区布局", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let saveItem = NSMenuItem(
            title: "保存当前窗口布局为预设…",
            action: #selector(saveWorkspacePresetAction),
            keyEquivalent: ""
        )
        sub.addItem(saveItem)
        let presets = state.settings.workspacePresets
        if !presets.isEmpty {
            sub.addItem(.separator())
            for preset in presets {
                let item = NSMenuItem(
                    title: "恢复「\(preset.name)」(\(preset.entries.count) 窗)",
                    action: #selector(applyWorkspacePresetAction(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = preset.id
                sub.addItem(item)
            }
            let delRoot = NSMenuItem(title: "删除布局预设", action: nil, keyEquivalent: "")
            let delMenu = NSMenu()
            for preset in presets {
                let item = NSMenuItem(
                    title: preset.name,
                    action: #selector(deleteWorkspacePresetAction(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = preset.id
                delMenu.addItem(item)
            }
            delRoot.submenu = delMenu
            sub.addItem(delRoot)
        }
        sub.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "清除已记忆的窗口位置 (\(state.settings.savedWindowLayouts.count))",
            action: #selector(clearSavedWindowLayoutsAction),
            keyEquivalent: ""
        )
        clearItem.isEnabled = !state.settings.savedWindowLayouts.isEmpty
        sub.addItem(clearItem)
        root.submenu = sub
        return root
    }
}
