import AppKit

struct TextDraft {
    var origin: CGPoint
    var text: String
    var fontSize: CGFloat
    var color: NSColor

    func attributed(_ string: String, alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
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

    // A origem é o canto superior esquerdo do texto: ele cresce para baixo, como num editor.
    static func draw(_ string: NSAttributedString, at origin: CGPoint) {
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let size = string.boundingRect(with: CGSize(width: 10000, height: 10000), options: options).size
        let rect = NSRect(
            x: origin.x,
            y: origin.y - ceil(size.height),
            width: ceil(size.width) + 4,
            height: ceil(size.height)
        )
        string.draw(with: rect, options: options)
    }
}

struct Shape {
    enum Kind {
        case freehand
        case line
        case rectangle
        case ellipse
        case arrow
        case text
    }

    var kind: Kind
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var highlighter: Bool
    var text: TextDraft?

    init(kind: Kind, points: [CGPoint], color: NSColor, width: CGFloat, highlighter: Bool) {
        self.kind = kind
        self.points = points
        self.color = color
        self.width = width
        self.highlighter = highlighter
    }

    init(text: TextDraft) {
        kind = .text
        points = [text.origin]
        color = text.color
        width = 0
        highlighter = false
        self.text = text
    }

    // Com modificador seguro, a forma vira geométrica; solto, volta ao traço livre.
    static func kind(for flags: NSEvent.ModifierFlags) -> Kind {
        let rectangleKey = flags.contains(.control) || flags.contains(.command)
        if rectangleKey && flags.contains(.shift) { return .arrow }
        if rectangleKey { return .rectangle }
        if flags.contains(.option) { return .ellipse }
        if flags.contains(.shift) { return .line }
        return .freehand
    }

    func draw() {
        if kind == .text {
            if let text { TextDraft.draw(text.attributed(text.text), at: text.origin) }
            return
        }
        guard let first = points.first else { return }
        let last = points.last ?? first
        let ink = highlighter ? color.withAlphaComponent(0.45) : color
        ink.setStroke()
        ink.setFill()

        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch kind {
        case .freehand:
            guard points.count > 1 else {
                let radius = width / 2
                NSBezierPath(ovalIn: NSRect(x: first.x - radius, y: first.y - radius, width: width, height: width)).fill()
                return
            }
            path.move(to: first)
            for index in 1 ..< points.count {
                let previous = points[index - 1]
                let point = points[index]
                path.curve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), controlPoint: previous)
            }
            path.line(to: last)
        case .line:
            path.move(to: first)
            path.line(to: last)
        case .rectangle:
            path.appendRect(Self.rect(first, last))
        case .ellipse:
            path.appendOval(in: Self.rect(first, last))
        case .arrow:
            path.move(to: first)
            path.line(to: last)
            appendArrowHead(to: path, from: first, to: last)
        case .text:
            break
        }
        path.stroke()
    }

    private func appendArrowHead(to path: NSBezierPath, from start: CGPoint, to end: CGPoint) {
        guard start != end else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(18, width * 4)
        let spread = CGFloat.pi / 7
        path.move(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        path.line(to: end)
        path.line(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
