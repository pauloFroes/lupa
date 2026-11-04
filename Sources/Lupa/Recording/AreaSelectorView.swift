import AppKit
import Carbon.HIToolbox

// Arraste para escolher a área da gravação. Devolve o retângulo em pontos da tela, com a
// origem no canto inferior esquerdo (coordenadas da view).
final class AreaSelectorView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private var start: CGPoint?
    private var selection: CGRect?
    private var mouse: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        selection = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 32, selection.height >= 32 else {
            start = nil
            self.selection = nil
            needsDisplay = true
            return
        }
        onFinish?(selection.integral)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: onFinish?(nil)
        case kVK_Return, kVK_ANSI_KeypadEnter: onFinish?(bounds)
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ink1000.withAlphaComponent(0.45).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            Theme.lime.setStroke()
            border.stroke()
            drawSizeLabel(for: selection)
        }
        HUD.drawBar(
            [.badge("área"), HUD.hint("arraste", "escolhe"), HUD.hint("↩", "tela inteira"), HUD.hint("esc", "cancela")],
            style: .primary,
            centerX: bounds.midX,
            bottom: 40,
            maxWidth: bounds.width - 32,
            alpha: 1
        )
    }

    private func drawSizeLabel(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let label = NSAttributedString(string: text, attributes: [
            .font: Theme.mono(12, .semibold),
            .foregroundColor: Theme.ink1000,
        ])
        let size = label.size()
        let pill = NSRect(x: rect.minX, y: rect.maxY + 8, width: size.width + 16, height: 24)
        Theme.lime.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
        label.draw(at: CGPoint(x: pill.minX + 8, y: pill.midY - size.height / 2))
    }
}

// Contagem 3-2-1 antes de gravar. A janela fecha antes do primeiro quadro.
final class CountdownView: NSView {
    var value = 3 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 220
        let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        Theme.ink900.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 6
        Theme.lime.setStroke()
        ring.stroke()
        let number = NSAttributedString(string: "\(value)", attributes: [
            .font: Theme.display(120, .semibold),
            .foregroundColor: Theme.paper100,
        ])
        let size = number.size()
        number.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
