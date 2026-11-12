import AppKit
import Carbon.HIToolbox

enum Action: String, CaseIterable, Identifiable, Codable {
    case zoom
    case draw
    case breakTimer
    case liveZoom
    case record

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoom: "Zoom"
        case .draw: "Desenhar"
        case .breakTimer: "Intervalo"
        case .liveZoom: "Zoom ao vivo"
        case .record: "Gravar tela"
        }
    }

    var defaultShortcut: Shortcut {
        let key = switch self {
        case .zoom: kVK_ANSI_1
        case .draw: kVK_ANSI_2
        case .breakTimer: kVK_ANSI_3
        case .liveZoom: kVK_ANSI_4
        case .record: kVK_ANSI_5
        }
        return Shortcut(keyCode: UInt32(key), modifiers: NSEvent.ModifierFlags.control.rawValue)
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt

    static let relevantFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt32, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevantFlags).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    // Ordem dos símbolos do macOS: ⌃ ⌥ ⇧ ⌘.
    var displayString: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Espaço", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let functionKeys: [Int: Int] = [
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey,
        kVK_F4: NSF4FunctionKey, kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey,
        kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey, kVK_F9: NSF9FunctionKey,
        kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
    ]

    static func name(for keyCode: UInt32) -> String {
        if let name = special[Int(keyCode)] { return name }
        return character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    static func keyEquivalent(for keyCode: UInt32) -> String? {
        if let scalar = functionKeys[Int(keyCode)].flatMap({ UnicodeScalar($0) }) {
            return String(Character(scalar))
        }
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        default: return character(for: keyCode)?.lowercased()
        }
    }

    // O caractere depende do layout de teclado ativo (ABNT2, US…), por isso o UCKeyTranslate.
    static func character(for keyCode: UInt32) -> String? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
