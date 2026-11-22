import AppKit
import Foundation
import Testing
@testable import WinBridgeCore

@Test func helloRoundTripWithPackedCodecs() throws {
    let hello = Hello(
        protocolVersion: 1,
        clientName: "MacBook Pro",
        authToken: "secret-123",
        displayScale: 2.0,
        supportedCodecs: [.h264AnnexB, .jpeg, .rawBgra]
    )
    let msg = ControlMessage(seq: 1, timestampUs: 987_654, payload: .hello(hello))
    let wire = msg.encode()
    let decoded = try ControlMessage.decode(from: wire)
    #expect(decoded == msg)
}

@Test func helloDecodesUnpackedRepeatedCodecs() throws {
    var w = ProtoWriter()
    w.writeUInt32(field: 1, 1)
    w.writeInt32(field: 5, VideoCodec.h264AnnexB.rawValue)
    w.writeInt32(field: 5, VideoCodec.jpeg.rawValue)
    let decoded = try Hello.decode(from: w.data)
    #expect(decoded.supportedCodecs == [.h264AnnexB, .jpeg])
}

@Test func windowInfoNegativeCoordinatesAndPopups() throws {
    let win = WindowInfo(
        windowId: 0x0000_0000_0012_3456,
        ownerWindowId: 0x0000_0000_0001_0002,
        pid: 4242,
        processName: "notepad.exe",
        title: "中文标题 — Notepad",
        kind: .popup,
        x: -1920,
        y: -48,
        width: 320,
        height: 240,
        offsetX: -12,
        offsetY: -8,
        dpi: 192,
        isMinimized: false,
        isMaximized: false,
        isResizable: true,
        hasAlpha: true,
        zOrder: 9,
        iconPng: Data([0x89, 0x50, 0x4E, 0x47])
    )
    let msg = ControlMessage(
        seq: 42,
        timestampUs: 123_456_789,
        payload: .windowUpdated(WindowUpdated(window: win, ackResizeSeq: 7))
    )
    let wire = msg.encode()
    let decoded = try ControlMessage.decode(from: wire)
    #expect(decoded == msg)

    // Verify exact Proto3 10-byte two's-complement negative int32 encoding (-1) matching prost
    var negWriter = ProtoWriter()
    negWriter.writeInt32(field: 7, -1)
    #expect([UInt8](negWriter.data) == [0x38, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
}

@Test func emptyOneofPayloadsPreserveVariant() throws {
    let listReq = ControlMessage(seq: 2, timestampUs: 10, payload: .listWindowsReq(ListWindowsRequest(includeIcons: false)))
    #expect(try ControlMessage.decode(from: listReq.encode()) == listReq)

    let emptyClip = ControlMessage(seq: 3, timestampUs: 20, payload: .clipboardSync(ClipboardSync(changeId: 9, content: .textUtf8(""))))
    #expect(try ControlMessage.decode(from: emptyClip.encode()) == emptyClip)
}

@Test func mouseKeyTextAndErrorRoundTrips() throws {
    let cases: [ControlMessage.Payload] = [
        .mouseEvent(MouseEvent(
            windowId: 100,
            kind: .wheel,
            normX: 0.25,
            normY: -0.1,
            button: .left,
            wheelDeltaX: -45.5,
            wheelDeltaY: 120.0,
            modifiers: KeyModifierMask([.lCtrl, .lShift]).rawValue
        )),
        .mouseEvent(MouseEvent(
            windowId: 100,
            kind: .relativeMove,
            modifiers: 0,
            deltaX: -12.5,
            deltaY: 7.25,
            isRelative: true
        )),
        .keyEvent(KeyEvent(windowId: 100, isDown: true, isRepeat: false, hidUsage: 0x04, modifiers: 4)),
        .textInput(TextInput(windowId: 100, text: "你好 WinBridge 🚀")),
        .resizeWindow(ResizeWindow(windowId: 100, width: 1280, height: 720, resizeSeq: 3)),
        .subscribeWindow(SubscribeWindow(windowId: 100, targetFps: 60, maxBitrateKbps: 15000, followPopups: true, captureMode: .monitorCrop)),
        .setAudioConfig(SetAudioConfig(enabled: true)),
        .setAudioConfig(SetAudioConfig(enabled: false)),
        .setAudioConfig(SetAudioConfig(enabled: true, codec: .opus, bitrateKbps: 64, scope: 1)),
        .listAppsReq(ListAppsRequest(includeIcons: true)),
        .listAppsRes(ListAppsResponse(apps: [
            AppEntry(appId: "0123456789abcdef", name: "MuMu模拟器12", source: "Desktop", iconPng: Data([0x89, 0x50])),
        ])),
        .launchApp(LaunchApp(appId: "0123456789abcdef", autoSubscribe: true, targetFps: 60, maxBitrateKbps: 15000, followPopups: true, captureMode: .monitorCrop)),
        .launchAppRes(LaunchAppResult(appId: "0123456789abcdef", started: true, message: "")),
        .hostError(HostError(windowId: 100, code: .displayDisconnected, message: "No monitor")),
        .setVideoConfig(SetVideoConfig(windowId: 0, profile: .text, adaptive: true, rttMs: 42)),
        .setVideoConfig(SetVideoConfig(windowId: 7, profile: .game, targetFps: 60, maxBitrateKbps: 8000, adaptive: false)),
    ]
    for (i, payload) in cases.enumerated() {
        let msg = ControlMessage(seq: UInt64(i + 1), timestampUs: 500, payload: payload)
        #expect(try ControlMessage.decode(from: msg.encode()) == msg)
    }
}

@Test func mediaFrameHeader32ByteLayoutMatchesWinHost() throws {
    let header = MediaFrameHeader(
        windowId: 0x0102_0304_0506_0708,
        timestampUs: 0x1122_3344_5566_7788,
        width: 1920,
        height: 1080,
        codec: .h264AnnexB,
        flags: [.keyframe],
        frameSeq: 513,
        payloadLen: 65536
    )
    let bytes = header.encode()
    #expect(bytes.count == 32)
    #expect(Data(bytes[0..<4]) == Data("WBMF".utf8))
    #expect(bytes[24] == 1) // H264
    #expect(bytes[25] == 1) // KEYFRAME

    let decoded = try MediaFrameHeader.decode(from: bytes)
    #expect(decoded == header)
}

@Test func byteStreamBufferSurvivesLargeCompactions() {
    var buf = ByteStreamBuffer()
    // Simulate a 200KB IDR keyframe followed immediately by a 32-byte next header in the same chunk.
    let bigFrame = Data((0..<200_000).map { UInt8($0 & 0xFF) })
    let nextHeader = Data((0..<32).map { UInt8(($0 + 7) & 0xFF) })
    var combined = Data()
    combined.append(bigFrame)
    combined.append(nextHeader)
    buf.append(combined)

    // Consuming > 65536 bytes while leftover bytes remain triggers compaction!
    let first = buf.takeExact(200_000)
    #expect(first == bigFrame)

    // Subsequent 32-byte read after compaction must NOT crash and must match exact bytes.
    let second = buf.takeExact(32)
    #expect(second == nextHeader)
    #expect(buf.availableCount == 0)

    // Repeat multiple chunked cycles across compaction boundaries.
    for round in 0..<5 {
        let payload = Data(repeating: UInt8(round + 1), count: 80_000)
        let tail = Data(repeating: UInt8(round + 100), count: 32)
        buf.append(payload + tail)
        #expect(buf.takeExact(80_000) == payload)
        #expect(buf.takeExact(32) == tail)
    }
}

@Test func cursorMapperDetectsHiddenAndTransparentCustomCursors() {
    #expect(CursorMapper.isEffectivelyHidden(CursorShape(cursorType: .hidden)))
    #expect(!CursorMapper.isEffectivelyHidden(CursorShape(cursorType: .arrow)))
    let transparent = CursorShape(cursorType: .custom, customRgba: Data(repeating: 0, count: 16), width: 2, height: 2)
    #expect(CursorMapper.isEffectivelyHidden(transparent))
    #expect(CursorMapper.visiblePixelCount(transparent) == 0)
    let visibleCustom = CursorShape(cursorType: .custom, customRgba: Data([255, 255, 255, 255]), width: 1, height: 1)
    #expect(!CursorMapper.isEffectivelyHidden(visibleCustom))
    #expect(CursorMapper.visiblePixelCount(visibleCustom) == 1)
    #expect(CursorMapper.resolvedCursorType(for: CursorShape(cursorType: .hidden), forceVisible: false) == .hidden)
    #expect(CursorMapper.resolvedCursorType(for: CursorShape(cursorType: .hidden), forceVisible: true) == .arrow)
    #expect(CursorMapper.resolvedCursorType(for: transparent, forceVisible: true) == .arrow)
    #expect(CursorMapper.resolvedCursorType(for: visibleCustom, forceVisible: true) == .custom)
}

@Test func cursorMapperBuildsPremultipliedRetinaCustomCursorAndCapsOversized4KCursors() {
    // Standard 32x32 stays 32x32pt
    let layout32 = CursorMapper.logicalLayout(pixelWidth: 32, pixelHeight: 32, hotspotX: 4, hotspotY: 6)
    #expect(layout32.size == NSSize(width: 32, height: 32))
    #expect(layout32.hotSpot == NSPoint(x: 4, y: 6))

    // 64x64 Retina scales down 2x to 32x32pt
    let layout64 = CursorMapper.logicalLayout(pixelWidth: 64, pixelHeight: 64, hotspotX: 10, hotspotY: 12)
    #expect(layout64.size == NSSize(width: 32, height: 32))
    #expect(layout64.hotSpot == NSPoint(x: 5, y: 6))

    // Oversized 256x256 4K custom game cursor is capped at 64x64pt so macOS never drops it
    let layout256 = CursorMapper.logicalLayout(pixelWidth: 256, pixelHeight: 256, hotspotX: 32, hotspotY: 64)
    #expect(layout256.size == NSSize(width: 64, height: 64))
    #expect(layout256.hotSpot == NSPoint(x: 8, y: 16))

    // Premultiplication check on semi-transparent straight RGBA pixel
    let rgba = Data([
        200, 100, 50, 128,  // straight semi-transparent
        255, 255, 255, 255, // opaque white
        123, 45, 67, 0,     // fully transparent (must zero RGB)
        0, 0, 255, 255,     // opaque blue
    ])
    let shape = CursorShape(
        cursorType: .custom,
        customRgba: rgba,
        width: 2,
        height: 2,
        hotspotX: 1,
        hotspotY: 0
    )
    let built = CursorMapper.buildCustomCursorImage(shape)
    #expect(built != nil)
    #expect(built?.image.size == NSSize(width: 2, height: 2))
    #expect(built?.hotSpot == NSPoint(x: 1, y: 0))
    let rep = built?.image.representations.first as? NSBitmapImageRep
    #expect(rep != nil)
    if let ptr = rep?.bitmapData {
        // (200 * 128 + 127) / 255 = 100, (100 * 128 + 127) / 255 = 50, (50 * 128 + 127) / 255 = 25
        #expect(ptr[0] == 100 && ptr[1] == 50 && ptr[2] == 25 && ptr[3] == 128)
        #expect(ptr[4] == 255 && ptr[5] == 255 && ptr[6] == 255 && ptr[7] == 255)
        #expect(ptr[8] == 0 && ptr[9] == 0 && ptr[10] == 0 && ptr[11] == 0)
        #expect(ptr[12] == 0 && ptr[13] == 0 && ptr[14] == 255 && ptr[15] == 255)
    }
}

@Test func filePullMessagesRoundTrip() throws {
    let list = ControlMessage(
        seq: 3,
        timestampUs: 1,
        payload: .listHostFilesRes(ListHostFilesResponse(
            path: "C:\\Users\\me\\Downloads\\WinBridge",
            entries: [HostFileEntry(name: "shot.png", sizeBytes: 12, isDir: false)],
            error: ""
        ))
    )
    #expect(try ControlMessage.decode(from: list.encode()) == list)
    let pull = ControlMessage(
        seq: 4,
        timestampUs: 2,
        payload: .filePullReq(FilePullRequest(requestId: 9, path: "clipboard:"))
    )
    #expect(try ControlMessage.decode(from: pull.encode()) == pull)
    let start = FileTransferStart(
        transferId: 9,
        targetWindowId: 0,
        fileName: "shot.png",
        totalBytes: 12,
        direction: FileTransferStart.directionToClient,
        requestId: 77
    )
    #expect(try FileTransferStart.decode(from: start.encode()) == start)
    let notice = ControlMessage(
        seq: 5,
        timestampUs: 3,
        payload: .clipboardFilesNotice(ClipboardFilesNotice(
            changeId: 42,
            files: [HostFileEntry(name: "report.pdf", sizeBytes: 1024, isDir: false)],
            totalBytes: 1024,
            skippedCount: 1
        ))
    )
    #expect(try ControlMessage.decode(from: notice.encode()) == notice)

    // Unknown future oneof field should decode safely as `.unknown` rather than disconnecting.
    var futureWriter = ProtoWriter()
    futureWriter.writeUInt64(field: 1, 99)
    futureWriter.writeMessage(field: 99, Data([0x08, 0x01]), forceEmit: true)
    let futureDecoded = try ControlMessage.decode(from: futureWriter.data)
    #expect(futureDecoded.payload == .unknown(99))
}

@Test func filePullHelpersHandleWindowsPathsAndUnsafeNames() {
    #expect(FilePullWindowController.parentHostPath(#"C:\Users\me\Downloads\WinBridge"#) == #"C:\Users\me\Downloads"#)
    #expect(FilePullWindowController.parentHostPath(#"C:\Users\me\Downloads\"#) == #"C:\Users\me"#)
    #expect(FilePullWindowController.parentHostPath(#"C:\Users"#) == #"C:\"#)
    #expect(FilePullWindowController.parentHostPath(#"C:\"#) == #"C:\"#)
    #expect(FilePullWindowController.parentHostPath("/Users/me/Downloads") == "/Users/me")
    #expect(FilePullWindowController.parentHostPath("/") == "/")

    #expect(AppState.sanitizeIncomingFileName(#"C:\evil\..\..\notes.txt"#) == "notes.txt")
    #expect(AppState.sanitizeIncomingFileName("..") == "winbridge-file.bin")
    #expect(AppState.sanitizeIncomingFileName(".") == "winbridge-file.bin")
    #expect(AppState.sanitizeIncomingFileName("") == "winbridge-file.bin")
    #expect(AppState.formatByteCount(512) == "512 B")
    #expect(AppState.formatByteCount(2048) == "2.0 KB")
    #expect(AppState.formatByteCount(5 * 1024 * 1024) == "5.0 MB")
}
