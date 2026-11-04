import AppKit

// Desenha o ícone 1024×1024 da Lupa: lente lime sobre tinta, com a sombra dura olive.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("uso: make-icon <saida.png>\n".data(using: .utf8)!)
    exit(1)
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: 100, y: 124, width: 800, height: 800)
let radius: CGFloat = 180
color(0x5E7018).setFill()
NSBezierPath(roundedRect: body.offsetBy(dx: 24, dy: -24), xRadius: radius, yRadius: radius).fill()
color(0x0F1421).setFill()
let card = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
card.fill()
color(0xF2F0ED).setStroke()
card.lineWidth = 10
card.stroke()

let center = CGPoint(x: 450, y: 574)
let lens = NSBezierPath(ovalIn: NSRect(x: center.x - 210, y: center.y - 210, width: 420, height: 420))
lens.lineWidth = 64
color(0xDCFE6E).setStroke()
lens.stroke()

let handle = NSBezierPath()
handle.move(to: CGPoint(x: center.x + 190, y: center.y - 190))
handle.line(to: CGPoint(x: center.x + 330, y: center.y - 330))
handle.lineWidth = 84
handle.lineCapStyle = .round
color(0xF2F0ED).setStroke()
handle.stroke()

let plus = NSBezierPath()
plus.move(to: CGPoint(x: center.x - 100, y: center.y))
plus.line(to: CGPoint(x: center.x + 100, y: center.y))
plus.move(to: CGPoint(x: center.x, y: center.y - 100))
plus.line(to: CGPoint(x: center.x, y: center.y + 100))
plus.lineWidth = 52
plus.lineCapStyle = .round
color(0xDCFE6E).setStroke()
plus.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
