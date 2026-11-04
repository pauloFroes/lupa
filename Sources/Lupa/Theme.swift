import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}

// Paleta e tipografia do Eduliv Design System (tinta, papel e o lime como único acento).
enum Theme {
    static let ink1000 = NSColor(hex: 0x0A0E18)
    static let ink900 = NSColor(hex: 0x0F1421)
    static let ink800 = NSColor(hex: 0x161D2E)
    static let ink700 = NSColor(hex: 0x2B3245)
    static let ink500 = NSColor(hex: 0x5C6373)
    static let ink300 = NSColor(hex: 0x9AA3B8)
    static let ink200 = NSColor(hex: 0xC6CBD7)
    static let ink100 = NSColor(hex: 0xE3E6EC)
    static let paper50 = NSColor(hex: 0xFAF9F6)
    static let paper100 = NSColor(hex: 0xF2F0ED)
    static let paper200 = NSColor(hex: 0xE7E4DF)
    static let lime = NSColor(hex: 0xDCFE6E)
    static let olive = NSColor(hex: 0x5E7018)
    static let success = NSColor(hex: 0x1F8A5B)
    static let successSoft = NSColor(hex: 0xDFF1E7)
    static let danger = NSColor(hex: 0xC8341E)
    static let dangerSoft = NSColor(hex: 0xFBE3DC)

    static func display(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        font(family: "Bricolage Grotesque", size: size, weight: weight)
            ?? .systemFont(ofSize: size, weight: weight)
    }

    static func text(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        font(family: "Manrope", size: size, weight: weight)
            ?? .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        font(family: "JetBrains Mono", size: size, weight: weight)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func tabular(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // As fontes vêm em Contents/Resources/Fonts (ATSApplicationFontsPath). Rodando fora do .app,
    // a família não existe e o NSFont devolve outra: por isso a conferência do familyName.
    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else {
            return nil
        }
        return font
    }
}

struct Pen {
    let key: String
    let name: String
    let color: NSColor
    let labelColor: NSColor
}

enum Pens {
    static let all: [Pen] = [
        Pen(key: "R", name: "Vermelho", color: NSColor(hex: 0xFF3B30), labelColor: Theme.paper50),
        Pen(key: "G", name: "Verde", color: NSColor(hex: 0x34C759), labelColor: Theme.ink1000),
        Pen(key: "B", name: "Azul", color: NSColor(hex: 0x0A84FF), labelColor: Theme.paper50),
        Pen(key: "O", name: "Laranja", color: NSColor(hex: 0xFF9500), labelColor: Theme.ink1000),
        Pen(key: "Y", name: "Amarelo", color: NSColor(hex: 0xFFD60A), labelColor: Theme.ink1000),
        Pen(key: "P", name: "Rosa", color: NSColor(hex: 0xFF2D92), labelColor: Theme.ink1000),
    ]

    static func index(forKey key: String) -> Int? {
        all.firstIndex { $0.key.lowercased() == key.lowercased() }
    }
}
