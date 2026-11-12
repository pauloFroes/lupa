import AppKit
import QuartzCore

/// The pointer drawn during live zoom, in the style of edited screencasts: the system cursor is
/// hidden and Lupa draws a larger one that follows the mouse on a spring, tilts with velocity and
/// dips on click.
///
/// `position` is in real screen coordinates. The live zoom camera reads it and then calls
/// `place(at:)` with where that point lands in the magnified image.
final class LiveCursor {
    struct Smoothing {
        let stiffness: CGFloat
        let damping: CGFloat
    }

    let layer = CALayer()
    private(set) var position: CGPoint = .zero

    private var velocity: CGVector = .zero
    private var scale: CGFloat = 1
    private var scaleVelocity: CGFloat = 0
    private var pressed = false
    private var isVisible = true
    private var lastTime: CFTimeInterval = 0
    private var cursorKey: String = ""
    private var lastCursorCheck: CFTimeInterval = 0
    private var lastHideCheck: CFTimeInterval = 0
    private var size: CGFloat
    private var smoothing: Smoothing
    private var backingScale: CGFloat = 2
    private var monitor: Any?

    init(size: CGFloat, smoothing: Smoothing) {
        self.size = size
        self.smoothing = smoothing
        layer.actions = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
            "anchorPoint": NSNull(), "hidden": NSNull(),
        ]
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
    }

    func start(at point: CGPoint, backingScale: CGFloat) {
        self.backingScale = backingScale
        layer.contentsScale = backingScale
        position = point
        velocity = .zero
        // Start at the system cursor's size so the hand-over does not pop.
        scale = 1 / size
        scaleVelocity = 0
        pressed = false
        lastTime = CACurrentMediaTime()
        cursorKey = ""
        refreshImage(force: true)
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        ) { [weak self] event in
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: self?.pressed = true
            default: self?.pressed = false
            }
        }
        SystemCursor.hide()
    }

    func jump(to point: CGPoint) {
        position = point
        velocity = .zero
        lastTime = CACurrentMediaTime()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        SystemCursor.show()
        layer.removeFromSuperlayer()
    }

    /// Advances the spring towards `target` (view coordinates) and returns the smoothed position.
    @discardableResult
    func step(toward target: CGPoint, visible: Bool) -> CGPoint {
        let now = CACurrentMediaTime()
        var remaining = min(now - lastTime, 1.0 / 20.0)
        lastTime = now

        // Short fixed steps keep the spring stable even with irregular frame times.
        let h: CFTimeInterval = 1.0 / 240.0
        let k = smoothing.stiffness
        let c = smoothing.damping
        let scaleTarget: CGFloat = pressed ? 0.8 : 1
        while remaining > 0 {
            let dt = CGFloat(min(remaining, h))
            remaining -= h
            let ax = k * (target.x - position.x) - c * velocity.dx
            let ay = k * (target.y - position.y) - c * velocity.dy
            velocity.dx += ax * dt
            velocity.dy += ay * dt
            position.x += velocity.dx * dt
            position.y += velocity.dy * dt

            let sa = 1400 * (scaleTarget - scale) - 48 * scaleVelocity
            scaleVelocity += sa * dt
            scale += scaleVelocity * dt
        }

        if now - lastCursorCheck > 1.0 / 15.0 {
            lastCursorCheck = now
            refreshImage(force: false)
        }

        if visible, now - lastHideCheck > 0.25 {
            lastHideCheck = now
            SystemCursor.enforce()
        }

        isVisible = visible
        return position
    }

    /// Draws the cursor at `point`, in view coordinates.
    func place(at point: CGPoint) {
        // Lean back against the direction of travel, as if the tip were pulling the cursor.
        let tilt = (-velocity.dx / 6000).clamped(-0.28, 0.28)
        var transform = CATransform3DMakeRotation(tilt, 0, 0, 1)
        transform = CATransform3DScale(transform, scale, scale, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = !isVisible
        layer.position = point
        layer.transform = transform
        CATransaction.commit()
    }

    func update(size: CGFloat, smoothing: Smoothing) {
        self.smoothing = smoothing
        if size != self.size {
            self.size = size
            refreshImage(force: true)
        }
    }

    private func refreshImage(force: Bool) {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        let hot = cursor.hotSpot
        let key = "\(image.size.width)x\(image.size.height)@\(hot.x),\(hot.y)#\(image.representations.count)"
        guard force || key != cursorKey else { return }
        cursorKey = key

        let pointSize = CGSize(width: image.size.width * size, height: image.size.height * size)
        guard pointSize.width > 0, pointSize.height > 0, let rendered = render(image, pointSize: pointSize) else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = rendered
        layer.bounds = CGRect(origin: .zero, size: pointSize)
        // `hotSpot` is measured from the top-left corner; the layer's y axis points up.
        layer.anchorPoint = CGPoint(
            x: hot.x / image.size.width,
            y: 1 - hot.y / image.size.height
        )
        CATransaction.commit()
    }

    private func render(_ image: NSImage, pointSize: CGSize) -> CGImage? {
        let width = Int((pointSize.width * backingScale).rounded(.up))
        let height = Int((pointSize.height * backingScale).rounded(.up))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        else { return nil }
        rep.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: CGRect(origin: .zero, size: pointSize), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        return rep.cgImage
    }
}
