import AppKit

/// Color and type tokens: ink and paper neutrals with lime as the single accent.
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
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// The bundled fonts live in `Contents/Resources/Fonts` (`ATSApplicationFontsPath`). Outside
    /// the app bundle, e.g. under `swift run`, the family is missing and `NSFont` silently
    /// substitutes another one, hence the `familyName` check before falling back to system fonts.
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
