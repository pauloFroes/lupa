import AppKit

/// The 3-2-1 countdown before recording. Its window closes before the first frame is captured.
final class CountdownView: NSView {
    var value = 3 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 220
        let circle = NSRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        Theme.ink900.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 6
        Theme.lime.setStroke()
        ring.stroke()
        let number = NSAttributedString(
            string: "\(value)",
            attributes: [
                .font: Theme.display(120, .semibold),
                .foregroundColor: Theme.paper100,
            ])
        let size = number.size()
        number.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
