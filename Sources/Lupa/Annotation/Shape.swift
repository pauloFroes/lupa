import AppKit

/// An annotation: a stroke, a geometric shape or a block of text.
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

    /// Modifier held while dragging → shape: ⇧ line, ⌃ or ⌘ rectangle, ⌥ ellipse, ⌃⇧ arrow.
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
                NSBezierPath(ovalIn: NSRect(x: first.x - radius, y: first.y - radius, width: width, height: width))
                    .fill()
                return
            }
            path.move(to: first)
            for index in 1..<points.count {
                let previous = points[index - 1]
                let point = points[index]
                path.curve(
                    to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), controlPoint: previous)
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

    /// Hit-tests the outline only, so erasing a stroke drawn inside a large rectangle does not
    /// also remove the rectangle.
    func hit(_ point: CGPoint, radius: CGFloat) -> Bool {
        let reach = radius + width / 2
        switch kind {
        case .text:
            return text?.frame.insetBy(dx: -radius, dy: -radius).contains(point) ?? false
        case .freehand:
            guard points.count > 1 else {
                return points.first.map { hypot($0.x - point.x, $0.y - point.y) <= reach } ?? false
            }
            return Self.near(polyline: points, point, reach)
        case .line, .arrow:
            return Self.near(polyline: [points.first ?? .zero, points.last ?? .zero], point, reach)
        case .rectangle:
            let r = Self.rect(points.first ?? .zero, points.last ?? .zero)
            let corners = [
                CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY),
            ]
            return Self.near(polyline: corners, point, reach)
        case .ellipse:
            let r = Self.rect(points.first ?? .zero, points.last ?? .zero)
            let outline = (0...64).map { step -> CGPoint in
                let angle = CGFloat(step) / 64 * 2 * .pi
                return CGPoint(x: r.midX + r.width / 2 * cos(angle), y: r.midY + r.height / 2 * sin(angle))
            }
            return Self.near(polyline: outline, point, reach)
        }
    }

    private static func near(polyline: [CGPoint], _ point: CGPoint, _ reach: CGFloat) -> Bool {
        guard polyline.count > 1 else { return false }
        for index in 1..<polyline.count where distance(point, polyline[index - 1], polyline[index]) <= reach {
            return true
        }
        return false
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).clamped(0, 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
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
