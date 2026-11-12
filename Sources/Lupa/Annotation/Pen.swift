import AppKit

struct Pen {
    /// The drawing-mode key that selects this pen. Letters follow the English color names.
    let key: String
    let name: String
    let color: NSColor
    /// Color of the key letter drawn on top of the swatch.
    let labelColor: NSColor
}

enum Pens {
    static let all: [Pen] = [
        Pen(key: "R", name: String(localized: "Red"), color: NSColor(hex: 0xFF3B30), labelColor: Theme.paper50),
        Pen(key: "G", name: String(localized: "Green"), color: NSColor(hex: 0x34C759), labelColor: Theme.ink1000),
        Pen(key: "B", name: String(localized: "Blue"), color: NSColor(hex: 0x0A84FF), labelColor: Theme.paper50),
        Pen(key: "O", name: String(localized: "Orange"), color: NSColor(hex: 0xFF9500), labelColor: Theme.ink1000),
        Pen(key: "Y", name: String(localized: "Yellow"), color: NSColor(hex: 0xFFD60A), labelColor: Theme.ink1000),
        Pen(key: "P", name: String(localized: "Pink"), color: NSColor(hex: 0xFF2D92), labelColor: Theme.ink1000),
    ]

    static func index(forKey key: String) -> Int? {
        all.firstIndex { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}
