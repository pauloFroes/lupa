import AVFoundation
import AppKit

/// The round camera overlay that is recorded along with the screen. It sits above the zoom and
/// drawing overlays (`.screenSaver + 1`) so it stays in the video while you zoom.
///
/// When the mouse actually heads for the bubble (moves towards it, or rests on or right next to
/// it for a moment), the bubble glides to the mirrored spot on the other side; merely passing by
/// does not move it. From there it only returns when the mouse heads for it again, or after
/// `awayStay` seconds once the mouse has left the area that chased it away. Holding ⌥ pins the
/// bubble so it can be dragged.
final class CameraBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "io.github.paulofroes.lupa.camera")
    private static let diameter: CGFloat = 220
    private static let margin: CGFloat = 32
    /// Only within this distance from the edge does mouse movement count as heading for the bubble.
    private static let approachDistance: CGFloat = 90
    /// A (nearly) resting mouse this close to the edge also wants the bubble's spot.
    private static let restDistance: CGFloat = 30
    /// Intent must last this long before the bubble moves, so a quick pass does not count.
    private static let intentHold: CFTimeInterval = 0.3
    /// Minimum stay at the away spot, unless the mouse heads for the bubble again.
    private static let awayStay: CFTimeInterval = 8
    /// After `awayStay`, the bubble returns once the mouse has been this far from the home spot
    /// for `returnHold`.
    private static let returnDistance: CGFloat = 200
    private static let returnHold: CFTimeInterval = 1.0

    private var screen: NSScreen?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    /// The chosen spot (window origin); changes when the bubble is dragged.
    private var home: CGPoint = .zero
    private var isAway = false
    // Slower than the cursor: the bubble glides rather than jumps.
    private var springX = Spring(value: 0, response: 0.9)
    private var springY = Spring(value: 0, response: 0.9)
    private var mouseVelocity = CGVector.zero
    private var lastMouse: CGPoint?
    private var intentSince: CFTimeInterval?
    private var clearSince: CFTimeInterval?
    private var movedAt: CFTimeInterval = 0
    private var lastSetOrigin: CGPoint = .zero
    private var isDragging = false
    /// Reports a new home spot after a drag, so the next recording starts there.
    var onMove: ((CGPoint) -> Void)?

    func show(on screen: NSScreen, at savedOrigin: CGPoint? = nil, cameraID: String? = nil) throws {
        guard panel == nil else { return }
        guard let device = Self.pickCamera(id: cameraID) else { return }
        let input = try AVCaptureDeviceInput(device: device)
        // Configure on the same queue as `hide()`. Otherwise the previous recording's teardown,
        // still queued, would remove the freshly added input and leave the bubble black.
        let session = session
        sessionQueue.sync {
            session.beginConfiguration()
            for existing in session.inputs { session.removeInput(existing) }
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
        }

        let size = Self.diameter
        var frame = NSRect(
            x: screen.visibleFrame.maxX - size - Self.margin,
            y: screen.visibleFrame.minY + Self.margin,
            width: size,
            height: size
        )
        if let savedOrigin {
            let saved = NSRect(origin: savedOrigin, size: frame.size)
            if screen.visibleFrame.contains(saved) { frame = saved }
        }
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = size / 2
        preview.masksToBounds = true
        preview.borderColor = Theme.lime.cgColor
        preview.borderWidth = 4
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.screen = screen
        home = frame.origin
        isAway = false
        isDragging = false
        springX.snap(to: frame.origin.x)
        springY.snap(to: frame.origin.y)
        lastSetOrigin = frame.origin
        startTracking()

        sessionQueue.async { session.startRunning() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let session = session
        sessionQueue.async {
            session.stopRunning()
            for existing in session.inputs { session.removeInput(existing) }
        }
    }

    /// Cameras offered in the recording panel.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.filter(\.isConnected)
    }

    /// The camera chosen in the panel. Without a choice (or if it is gone) the built-in camera
    /// wins: the system default may be a virtual camera or an iPhone, which show black when idle.
    static func pickCamera(id: String?) -> AVCaptureDevice? {
        if let id, let chosen = AVCaptureDevice(uniqueID: id), chosen.isConnected, !chosen.isSuspended {
            return chosen
        }
        let devices = devices().filter { !$0.isSuspended }
        return devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first { $0.deviceType == .external }
            ?? devices.first
            ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - Dodging the mouse

    private func startTracking() {
        timer?.invalidate()
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let panel else { return }
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        let mouse = NSEvent.mouseLocation

        // While dragging, the window moves itself; on release the new spot becomes home.
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed {
            if !isDragging, !panel.ignoresMouseEvents, panel.frame.contains(mouse) { isDragging = true }
            if isDragging { return }
        } else if isDragging {
            isDragging = false
            let origin = clamped(panel.frame.origin)
            home = origin
            onMove?(origin)
            isAway = false
            springX.snap(to: origin.x)
            springY.snap(to: origin.y)
            setOrigin(origin)
            return
        }
        // If something else moved the window, adopt the new position instead of fighting it.
        if panel.frame.origin != lastSetOrigin, !isAway {
            home = panel.frame.origin
            springX.snap(to: home.x)
            springY.snap(to: home.y)
            lastSetOrigin = home
        }

        trackVelocity(mouse, dt: dt)
        let holdingOption = NSEvent.modifierFlags.contains(.option)
        let away = awayOrigin()
        if holdingOption {
            intentSince = nil
            clearSince = nil
        } else {
            decide(mouse: mouse, away: away, now: now)
        }

        // While gliding, clicks pass through to the app below and the bubble cannot be grabbed mid-flight.
        let moving = !(springX.isSettled && springY.isSettled)
        if panel.ignoresMouseEvents != moving { panel.ignoresMouseEvents = moving }

        let target = isAway ? away : home
        springX.target = target.x
        springY.target = target.y
        guard !(springX.isSettled && springY.isSettled && panel.frame.origin == target) else { return }
        springX.step(dt)
        springY.step(dt)
        setOrigin(CGPoint(x: springX.value.rounded(), y: springY.value.rounded()))
    }

    private func trackVelocity(_ mouse: CGPoint, dt: Double) {
        defer { lastMouse = mouse }
        guard let last = lastMouse, dt > 0 else { return }
        let instant = CGVector(dx: (mouse.x - last.x) / dt, dy: (mouse.y - last.y) / dt)
        // ~80 ms exponential moving average: removes jitter without delaying the heading.
        let a = CGFloat(1 - exp(-dt / 0.08))
        mouseVelocity.dx += (instant.dx - mouseVelocity.dx) * a
        mouseVelocity.dy += (instant.dy - mouseVelocity.dy) * a
    }

    private func decide(mouse: CGPoint, away: CGPoint, now: CFTimeInterval) {
        let occupied = isAway ? away : home
        let other = isAway ? home : away
        let stayedLongEnough = now - movedAt > Self.awayStay

        // The mouse wants the bubble's current spot: move to the other one if that is free.
        if wantsSpot(mouse: mouse, bubbleAt: occupied), distance(from: mouse, toBubbleAt: other) > Self.approachDistance
        {
            let since = intentSince ?? now
            intentSince = since
            if now - since >= Self.intentHold { move(away: !isAway, now: now) }
        } else {
            intentSince = nil
        }

        // Away from home, return only after `awayStay` and with the mouse clear of the home area.
        if isAway, distance(from: mouse, toBubbleAt: home) > Self.returnDistance {
            let since = clearSince ?? now
            clearSince = since
            if stayedLongEnough, now - since >= Self.returnHold { move(away: false, now: now) }
        } else {
            clearSince = nil
        }
    }

    private func move(away: Bool, now: CFTimeInterval) {
        isAway = away
        movedAt = now
        intentSince = nil
        clearSince = nil
    }

    /// Intent to reach the bubble: on top of it, resting right next to it, or heading towards it.
    private func wantsSpot(mouse: CGPoint, bubbleAt origin: CGPoint) -> Bool {
        let d = distance(from: mouse, toBubbleAt: origin)
        if d > Self.approachDistance { return false }
        let speed = hypot(mouseVelocity.dx, mouseVelocity.dy)
        // Crossing the bubble quickly is passing through, not intent.
        if d <= 0 { return speed < 600 }
        if speed < 60 { return d < Self.restDistance }
        let radius = Self.diameter / 2
        let center = CGPoint(x: origin.x + radius, y: origin.y + radius)
        let toCenter = CGVector(dx: center.x - mouse.x, dy: center.y - mouse.y)
        let length = max(1, hypot(toCenter.dx, toCenter.dy))
        let heading = (mouseVelocity.dx * toCenter.dx + mouseVelocity.dy * toCenter.dy) / (speed * length)
        // Keeping this course for 0.3 s brings the mouse to the bubble.
        let ahead = CGPoint(x: mouse.x + mouseVelocity.dx * 0.3, y: mouse.y + mouseVelocity.dy * 0.3)
        return heading > 0.6 && distance(from: ahead, toBubbleAt: origin) < d
    }

    private func setOrigin(_ origin: CGPoint) {
        lastSetOrigin = origin
        if panel?.frame.origin != origin { panel?.setFrameOrigin(origin) }
    }

    /// Distance from the mouse to the edge of a bubble at `origin` (negative inside it).
    private func distance(from mouse: CGPoint, toBubbleAt origin: CGPoint) -> CGFloat {
        let radius = Self.diameter / 2
        let center = CGPoint(x: origin.x + radius, y: origin.y + radius)
        return hypot(mouse.x - center.x, mouse.y - center.y) - radius
    }

    /// The away spot: home mirrored to the far side of the screen.
    private func awayOrigin() -> CGPoint {
        guard let frame = screen?.visibleFrame else { return home }
        let size = Self.diameter
        let mirroredX = frame.minX + frame.maxX - size - home.x
        let mirroredY = frame.minY + frame.maxY - size - home.y
        let dx = abs(mirroredX - home.x)
        let dy = abs(mirroredY - home.y)
        let point =
            dx >= size + Self.approachDistance || dx >= dy
            ? CGPoint(x: mirroredX, y: home.y)
            : CGPoint(x: home.x, y: mirroredY)
        return clamped(point)
    }

    private func clamped(_ origin: CGPoint) -> CGPoint {
        guard let frame = screen?.visibleFrame else { return origin }
        let size = Self.diameter
        return CGPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size),
            y: min(max(origin.y, frame.minY), frame.maxY - size)
        )
    }
}
