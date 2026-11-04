import AppKit

enum HUDSegment {
    case badge(String)
    case tool(String)
    case hint([(String, Bool)])
    case swatches(selected: Int, highlighter: Bool)
    case separator
    case penWidth(NSColor, String)
    case group(String)
}

enum HUDStyle {
    case primary
    case secondary
}

// Barras de dica desenhadas direto na view da sobreposição, no visual do design:
// pílula de tinta com borda ink-700, rótulo lime para o estado e teclas em mono.
enum HUD {
    private struct Metrics {
        let height: CGFloat
        let padding: CGFloat
        let gap: CGFloat
        let fontSize: CGFloat
        let radius: CGFloat
        let fill: NSColor
    }

    private static func metrics(_ style: HUDStyle) -> Metrics {
        switch style {
        case .primary:
            Metrics(height: 52, padding: 8, gap: 16, fontSize: 13, radius: 26, fill: Theme.ink900.withAlphaComponent(0.95))
        case .secondary:
            Metrics(height: 32, padding: 16, gap: 14, fontSize: 12, radius: 12, fill: Theme.ink900.withAlphaComponent(0.86))
        }
    }

    static func hint(_ key: String, _ label: String) -> HUDSegment {
        .hint([(key, true), (" " + label, false)])
    }

    @discardableResult
    static func drawBar(
        _ segments: [HUDSegment],
        style: HUDStyle,
        centerX: CGFloat,
        bottom: CGFloat,
        maxWidth: CGFloat,
        alpha: CGFloat
    ) -> CGFloat {
        guard alpha > 0, !segments.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return 0 }
        let m = metrics(style)
        let widths = segments.map { width(of: $0, m) }
        let trailing: CGFloat = if case .hint = segments.last { m.padding + 14 } else { m.padding }
        let total = widths.reduce(0, +) + m.gap * CGFloat(segments.count - 1) + m.padding + trailing
        let scale = min(1, maxWidth / total)

        context.saveGState()
        context.translateBy(x: centerX, y: bottom)
        context.scaleBy(x: scale, y: scale)
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        let background = NSRect(x: -total / 2, y: 0, width: total, height: m.height)
        let pill = NSBezierPath(roundedRect: background, xRadius: m.radius, yRadius: m.radius)
        m.fill.setFill()
        pill.fill()
        Theme.ink700.setStroke()
        pill.lineWidth = 1
        pill.stroke()

        var x = background.minX + m.padding
        for (segment, segmentWidth) in zip(segments, widths) {
            draw(segment, x: x, midY: m.height / 2, metrics: m)
            x += segmentWidth + m.gap
        }

        context.endTransparencyLayer()
        context.restoreGState()
        return m.height * scale
    }

    static func fadeAlpha(until: Date, now: Date = Date()) -> CGFloat {
        let remaining = until.timeIntervalSince(now)
        if remaining >= 0 { return 1 }
        if remaining <= -0.35 { return 0 }
        return CGFloat(1 + remaining / 0.35)
    }

    private static func hintString(_ parts: [(String, Bool)], size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, isKey) in parts {
            result.append(NSAttributedString(string: text, attributes: [
                .font: isKey ? Theme.mono(size, .medium) : Theme.text(size, .medium),
                .foregroundColor: isKey ? Theme.paper100 : Theme.ink200,
            ]))
        }
        return result
    }

    private static func badgeString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Theme.mono(15, .semibold),
            .foregroundColor: Theme.ink1000,
        ])
    }

    private static func toolString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Theme.text(13, .bold),
            .foregroundColor: Theme.ink1000,
        ])
    }

    private static func groupString(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: Theme.mono(size - 1, .semibold),
            .foregroundColor: Theme.lime,
            .kern: 1.2,
        ])
    }

    private static func labelString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Theme.mono(13, .medium),
            .foregroundColor: Theme.ink200,
        ])
    }

    private static func width(of segment: HUDSegment, _ m: Metrics) -> CGFloat {
        switch segment {
        case let .badge(text): ceil(badgeString(text).size().width) + 28
        case let .tool(text): ceil(toolString(text).size().width) + 28
        case let .hint(parts): ceil(hintString(parts, size: m.fontSize).size().width)
        case .swatches: CGFloat(Pens.all.count) * 32 + CGFloat(Pens.all.count - 1) * 6
        case .separator: 1
        case let .penWidth(_, label): 14 + 8 + ceil(labelString(label).size().width)
        case let .group(text): ceil(groupString(text, size: m.fontSize).size().width)
        }
    }

    private static func draw(_ segment: HUDSegment, x: CGFloat, midY: CGFloat, metrics m: Metrics) {
        switch segment {
        case let .badge(text):
            drawPill(badgeString(text), x: x, midY: midY)
        case let .tool(text):
            drawPill(toolString(text), x: x, midY: midY)
        case let .hint(parts):
            let string = hintString(parts, size: m.fontSize)
            string.draw(at: CGPoint(x: x, y: midY - string.size().height / 2))
        case let .swatches(selected, highlighter):
            drawSwatches(selected: selected, highlighter: highlighter, x: x, midY: midY)
        case .separator:
            Theme.ink700.setFill()
            NSRect(x: x, y: midY - 14, width: 1, height: 28).fill()
        case let .penWidth(color, label):
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - 7, width: 14, height: 14)).fill()
            let string = labelString(label)
            string.draw(at: CGPoint(x: x + 22, y: midY - string.size().height / 2))
        case let .group(text):
            let string = groupString(text, size: m.fontSize)
            string.draw(at: CGPoint(x: x, y: midY - string.size().height / 2))
        }
    }

    private static func drawPill(_ string: NSAttributedString, x: CGFloat, midY: CGFloat) {
        let size = string.size()
        let rect = NSRect(x: x, y: midY - 18, width: ceil(size.width) + 28, height: 36)
        Theme.lime.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
        string.draw(at: CGPoint(x: x + 14, y: midY - size.height / 2))
    }

    private static func drawSwatches(selected: Int, highlighter: Bool, x: CGFloat, midY: CGFloat) {
        for (index, pen) in Pens.all.enumerated() {
            let center = CGPoint(x: x + CGFloat(index) * 38 + 16, y: midY)
            if index == selected {
                Theme.lime.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)).fill()
                Theme.ink900.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36)).fill()
            }
            let alpha: CGFloat = index == selected && highlighter ? 0.55 : 1
            pen.color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)).fill()
            let letter = NSAttributedString(string: pen.key, attributes: [
                .font: Theme.mono(12, .semibold),
                .foregroundColor: pen.labelColor,
            ])
            let size = letter.size()
            letter.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        }
    }
}
