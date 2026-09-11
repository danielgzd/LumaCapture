import AppKit
import Carbon

struct HotkeyConfiguration: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayName: String

    static let defaultScreenshot = HotkeyConfiguration(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘2")
    static let defaultRecording = HotkeyConfiguration(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘6")

    init(keyCode: UInt32, carbonModifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayName = displayName
    }

    init(keyCode: Int, carbonModifiers: Int, displayName: String, fallback: HotkeyConfiguration) {
        if keyCode > 0 && !displayName.isEmpty {
            self.init(keyCode: UInt32(keyCode), carbonModifiers: UInt32(max(0, carbonModifiers)), displayName: displayName)
        } else {
            self = fallback
        }
    }
}

@MainActor
final class GlobalHotkeys {
    var onScreenshot: (() -> Void)?
    var onRecording: (() -> Void)?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    func register(screenshot: HotkeyConfiguration, recording: HotkeyConfiguration) throws {
        guard screenshot != recording else { throw AppFailure("截图和录屏不能使用相同的快捷键。") }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if key.id == 1 { manager.onScreenshot?() }
                if key.id == 2 { manager.onRecording?() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw AppFailure("无法安装快捷键处理器（\(status)）。") }
        for (identifier, shortcut) in [(UInt32(1), screenshot), (UInt32(2), recording)] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: 0x4C554D41, id: identifier), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { throw AppFailure("\(shortcut.displayName) 已被占用或无法注册。请换一个组合。（\(result)）") }
            references.append(ref)
        }
    }
    deinit {
        for ref in references { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
