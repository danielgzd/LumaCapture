import AppKit
import Carbon

struct HotkeyConfiguration: Equatable {
    var key: String
    var command: Bool = true
    var shift: Bool = true
    var option: Bool = false
    var control: Bool = false

    var displayName: String {
        "\(control ? "⌃" : "")\(option ? "⌥" : "")\(shift ? "⇧" : "")\(command ? "⌘" : "")\(key.uppercased())"
    }

    var carbonModifiers: UInt32 {
        (command ? UInt32(cmdKey) : 0) | (shift ? UInt32(shiftKey) : 0) |
        (option ? UInt32(optionKey) : 0) | (control ? UInt32(controlKey) : 0)
    }

    var keyCode: UInt32? {
        let codes: [Character: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z
        ]
        guard key.count == 1, let character = key.lowercased().first, let code = codes[character] else { return nil }
        return UInt32(code)
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
            guard let code = shortcut.keyCode, shortcut.carbonModifiers != 0 else { throw AppFailure("快捷键需要一个字母或数字，并至少选择一个修饰键。") }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(code, shortcut.carbonModifiers, EventHotKeyID(signature: 0x4C554D41, id: identifier), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { throw AppFailure("\(shortcut.displayName) 已被占用或无法注册。请换一个组合。（\(result)）") }
            references.append(ref)
        }
    }
    deinit {
        for ref in references { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
