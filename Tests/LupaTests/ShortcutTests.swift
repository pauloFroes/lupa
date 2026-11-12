import AppKit
import Carbon.HIToolbox
import Testing

@testable import Lupa

struct ShortcutTests {
    @Test func dropsIrrelevantModifierFlags() {
        let raw = NSEvent.ModifierFlags([.control, .capsLock, .function, .numericPad]).rawValue
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: raw)
        #expect(shortcut.flags == [.control])
    }

    @Test func convertsToCarbonModifiers() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: flags.rawValue)
        #expect(shortcut.carbonModifiers == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }

    @Test func modifierSymbolsFollowMenuOrder() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let shortcut = Shortcut(keyCode: UInt32(kVK_F5), modifiers: flags.rawValue)
        #expect(shortcut.modifierSymbols == "⌃⌥⇧⌘")
        #expect(shortcut.displayString == "⌃⌥⇧⌘F5")
    }

    @Test func addingShift() {
        let record = Action.record.defaultShortcut
        #expect(record.addingShift?.flags == [.control, .shift])
        #expect(record.addingShift?.addingShift == nil)
    }

    @Test func defaultShortcutsAreDistinct() {
        let defaults = Action.allCases.map(\.defaultShortcut)
        for (index, shortcut) in defaults.enumerated() {
            #expect(!defaults[(index + 1)...].contains(shortcut))
        }
    }

    @Test func roundTripsThroughCodable() throws {
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: NSEvent.ModifierFlags.option.rawValue)
        let data = try JSONEncoder().encode(shortcut)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == shortcut)
    }
}
