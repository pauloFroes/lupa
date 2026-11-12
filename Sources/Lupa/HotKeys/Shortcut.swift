import AppKit
import Carbon.HIToolbox

/// The modes reachable through a global shortcut.
enum Action: String, CaseIterable, Identifiable, Codable {
    case zoom
    case draw
    case breakTimer
    case liveZoom
    case record

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoom: String(localized: "Zoom")
        case .draw: String(localized: "Draw")
        case .breakTimer: String(localized: "Break")
        case .liveZoom: String(localized: "Live zoom")
        case .record: String(localized: "Record screen")
        }
    }

    var defaultShortcut: Shortcut {
        let key =
            switch self {
            case .zoom: kVK_ANSI_1
            case .draw: kVK_ANSI_2
            case .breakTimer: kVK_ANSI_3
            case .liveZoom: kVK_ANSI_4
            case .record: kVK_ANSI_5
            }
        return Shortcut(keyCode: UInt32(key), modifiers: NSEvent.ModifierFlags.control.rawValue)
    }
}

/// A key plus modifiers, stored with AppKit modifier flags and converted to Carbon on demand.
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

    /// The same shortcut with ⇧ added, or `nil` if it already uses ⇧.
    var addingShift: Shortcut? {
        guard !flags.contains(.shift) else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers | NSEvent.ModifierFlags.shift.rawValue)
    }

    /// Modifier glyphs in the order macOS menus use: ⌃ ⌥ ⇧ ⌘.
    var modifierSymbols: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    var displayString: String { modifierSymbols + KeyNames.name(for: keyCode) }
}
