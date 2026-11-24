import Foundation
import Testing
@testable import WinBridgeCore

@Suite("v0.5 Phase 3 — Windows Toast Notification Forwarding")
struct V05Phase3Tests {
    @Test("HostNotification protobuf and ControlMessage field 69 round-trip cleanly")
    func hostNotificationProtobufRoundTrip() throws {
        let note = HostNotification(
            notificationId: 4201,
            appName: "微信",
            processName: "WeChat.exe",
            title: "Alice",
            body: "晚上一起吃火锅吗？",
            windowId: 0x0012_3456,
            timestampMs: 1_760_000_000_123
        )
        let decodedNote = try HostNotification.decode(from: note.encode())
        #expect(decodedNote == note)

        let envelope = ControlMessage(seq: 77, timestampUs: 999_000, payload: .hostNotification(note))
        let decodedEnv = try ControlMessage.decode(from: envelope.encode())
        #expect(decodedEnv == envelope)
    }

    @Test("ProtocolCapabilities includes notifications bit and v0.5.x version")
    func notificationsCapabilityBitAndVersion() {
        #expect(ProtocolCapabilities.currentAppVersion == "0.5.4")
        #expect(ProtocolCapabilities.notifications == (1 << 7))
        #expect((ProtocolCapabilities.clientSupported & ProtocolCapabilities.notifications) != 0)
    }

    @Test("NotificationForwarder formats banners cleanly and never crashes unbundled")
    func bannerFormattingAndUnbundledSafety() {
        #expect(!NotificationForwarder.isBundledApp)

        let full = NotificationForwarder.formatBanner(from: HostNotification(
            notificationId: 1,
            appName: "Discord",
            processName: "Discord.exe",
            title: "#general",
            body: "Build passed!",
            windowId: 0,
            timestampMs: 0
        ))
        #expect(full == NotificationBannerContent(title: "Discord", subtitle: "#general", body: "Build passed!"))

        let titleOnly = NotificationForwarder.formatBanner(from: HostNotification(
            notificationId: 2,
            appName: "",
            processName: "",
            title: "Windows Update 完成",
            body: "",
            windowId: 0,
            timestampMs: 0
        ))
        #expect(titleOnly == NotificationBannerContent(title: "Windows 通知", subtitle: "", body: "Windows Update 完成"))
    }

    @Test("NotificationForwarder selects target window by ID, exact process, stem, or title")
    func targetWindowSelection() {
        let wechat = WindowInfo(windowId: 0x101, processName: "WeChat.exe", title: "微信", kind: .normal)
        let whatsapp = WindowInfo(windowId: 0x202, processName: "WhatsApp.exe", title: "WhatsApp", kind: .normal)
        let popup = WindowInfo(windowId: 0x303, processName: "Discord.exe", title: "Menu", kind: .popup)
        let all = [wechat, whatsapp, popup]

        // Exact window ID wins
        #expect(NotificationForwarder.selectTargetWindow(
            windowId: 0x202, processName: "WeChat.exe", appName: "微信", availableWindows: all
        )?.windowId == 0x202)

        // Exact process match when windowId == 0
        #expect(NotificationForwarder.selectTargetWindow(
            windowId: 0, processName: "wechat.exe", appName: "微信", availableWindows: all
        )?.windowId == 0x101)

        // Stem match (UWP WhatsAppDesktop.exe -> WhatsApp.exe)
        #expect(NotificationForwarder.selectTargetWindow(
            windowId: 0, processName: "WhatsAppDesktop.exe", appName: "WhatsApp", availableWindows: all
        )?.windowId == 0x202)

        // Popups are never targeted
        #expect(NotificationForwarder.selectTargetWindow(
            windowId: 0, processName: "Discord.exe", appName: "Discord", availableWindows: all
        ) == nil)
    }
}
