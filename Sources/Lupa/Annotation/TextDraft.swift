import AppKit

/// Text being typed in drawing mode; committed as a `.text` shape when finished.
struct TextDraft {
    var origin: CGPoint
    var text: String
    var fontSize: CGFloat
    var color: NSColor

    func attributed(_ string: String, alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: Theme.text(fontSize, .bold),
                .foregroundColor: color.withAlphaComponent(alpha),
            ])
    }

    func draw(marked: String, caret: Bool) {
        let full = NSMutableAttributedString(attributedString: attributed(text))
        if !marked.isEmpty {
            let pending = NSMutableAttributedString(attributedString: attributed(marked, alpha: 0.6))
            pending.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: pending.length)
            )
            full.append(pending)
        }
        if caret { full.append(attributed("▏", alpha: 0.9)) }
        Self.draw(full, at: origin)
    }

    var frame: NSRect { Self.frame(of: attributed(text), at: origin) }

    private static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// `origin` is the text's top-left corner, so it grows downwards like in an editor.
    static func frame(of string: NSAttributedString, at origin: CGPoint) -> NSRect {
        let size = string.boundingRect(with: CGSize(width: 10000, height: 10000), options: options).size
        return NSRect(
            x: origin.x,
            y: origin.y - ceil(size.height),
            width: ceil(size.width) + 4,
            height: ceil(size.height)
        )
    }

    static func draw(_ string: NSAttributedString, at origin: CGPoint) {
        string.draw(with: frame(of: string, at: origin), options: options)
    }
}
