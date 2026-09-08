import AppKit
import Carbon

@MainActor
final class GlobalHotkeys {
    var onScreenshot: (() -> Void)?
    var onRecording: (() -> Void)?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    func register() throws {
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
        for (identifier, code) in [(UInt32(1), UInt32(kVK_ANSI_2)), (UInt32(2), UInt32(kVK_ANSI_6))] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4C554D41, id: identifier), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { throw AppFailure("⌘⇧\(identifier == 1 ? "2" : "6") 已被占用或无法注册。可在设置关闭快捷键。（\(result)）") }
            references.append(ref)
        }
    }
    deinit {
        for ref in references { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
