import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit

/// Live zoom: an `SCStream` of the display (minus Lupa's own windows) drawn into a click-through
/// window, magnified around the pointer while you keep using your apps.
///
/// The camera chases the spring-smoothed cursor (`LiveCursor`) to keep it centered, with a slight
/// lag, and reaches the screen edge before the cursor does; there it stops and only the cursor
/// moves on. The cursor is drawn where the real mouse position lands in the magnified image, so
/// once it rests, a click hits exactly what is under it.
///
/// Entry waits for the first frame so it can start at a pixel-identical 1×; exit plays the same
/// curve backwards.
final class LiveZoomController: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isActive = false
    var onStop: (() -> Void)?

    private var window: OverlayWindow?
    private var stream: SCStream?
    private(set) var screen: NSScreen?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private enum Phase { case waitingForFrame, entering, live, leaving }
    private var phase = Phase.waitingForFrame
    private var phaseStart: CFTimeInterval = 0
    private var leavingLogZoom = 0.0
    private var leavingDisplay = CGPoint.zero
    private var border: CALayer?
    // Zoom is animated in log space: 2× → 4× takes as long as 4× → 8×, which is what the eye expects.
    private var logZoom = Spring(value: 0, response: 0.42)
    private var cameraX = Spring(value: 0, response: 0.53)
    private var cameraY = Spring(value: 0, response: 0.53)
    private var cursor: LiveCursor?
    private var cursorOnScreen = true
    private var prefsObserver: AnyCancellable?
    private var targetZoom: CGFloat = 2
    private var initialZoom: CGFloat = 2
    private var hud: LiveHUDView?
    private let contentLayer = CALayer()
    private var lastApplied: (CGFloat, CGPoint) = (0, CGPoint(x: -1, y: -1))
    static let zoomRange: ClosedRange<CGFloat> = 1...8
    /// Fraction of the visible span, on each side, that camera lag may never push the cursor into.
    static let cursorMargin = 0.1
    static let transitionDuration = 0.7
    static let fadeDuration = 0.3
    private let queue = DispatchQueue(label: "io.github.paulofroes.lupa.live-zoom")

    // Auto zoom, used while recording: start at 1×, zoom in where you click and settle back to 1×
    // once the mouse rests, like an edited screencast. No border or badge, since they would be
    // recorded.
    private(set) var autoZoom = false
    private var autoZoomLevel: CGFloat = 2
    private var clickMonitor: Any?
    private let clickTap = EventTap()
    private var lastActivity: CFTimeInterval = 0
    private var lastMouse = CGPoint.zero
    static let autoZoomIdle: CFTimeInterval = 2.5

    // Live drawing: frames keep arriving, but camera and zoom freeze so strokes stay on the same
    // spot of the content. The drawn cursor hides; the pen preview is the cursor.
    private(set) var drawing = false
    var isLive: Bool { isActive && phase == .live }

    func setDrawing(_ on: Bool) {
        guard isActive, on != drawing else { return }
        drawing = on
        if !on {
            lastActivity = CACurrentMediaTime()
            lastMouse = NSEvent.mouseLocation
            if let screen { cursor?.jump(to: cursorPoint(in: screen.frame)) }
        }
    }

    @MainActor
    func start(on screen: NSScreen, zoom initialZoom: CGFloat, autoZoom: Bool = false) async throws {
        // Put the (still empty) window on screen before building the filter, so Lupa is guaranteed
        // to be in the application list the filter excludes.
        contentLayer.contents = nil
        let window = OverlayWindow(screen: screen)
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        do {
            let filter = try await ScreenCapture.filter(for: screen, requireExclusion: true)
            let configuration = ScreenCapture.configuration(for: screen)
            let fps = Int32(max(60, screen.maximumFramesPerSecond))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: fps)
            configuration.queueDepth = 5
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.autoZoom = autoZoom
            autoZoomLevel = initialZoom.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
            present(in: window, on: screen, stream: stream, zoom: autoZoom ? 1 : initialZoom)
            if autoZoom { startClickMonitors() }
        } catch {
            window.orderOut(nil)
            throw error
        }
    }

    /// When `animated`, zoom eases back to 1× before the window closes.
    func stop(animated: Bool = false) {
        guard isActive else { return }
        if animated, phase == .leaving { return }
        if animated, phase != .waitingForFrame, let screen {
            let point = cursor?.position ?? cursorPoint(in: screen.frame)
            let zoom = exp(logZoom.value)
            leavingDisplay = CGPoint(x: (point.x - cameraX.value) * zoom, y: (point.y - cameraY.value) * zoom)
            leavingLogZoom = logZoom.value
            phase = .leaving
            phaseStart = CACurrentMediaTime()
            return
        }
        isActive = false
        drawing = false
        phase = .waitingForFrame
        stopClickMonitors()
        autoZoom = false
        border = nil
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        prefsObserver = nil
        cursor?.stop()
        cursor = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        window?.orderOut(nil)
        window = nil
        hud = nil
        contentLayer.contents = nil
        contentLayer.removeFromSuperlayer()
        lastApplied = (0, CGPoint(x: -1, y: -1))
        onStop?()
    }

    func adjust(by factor: CGFloat) {
        guard isActive, phase == .live, !drawing else { return }
        var next = targetZoom * factor
        // Snap to 1× only when zooming out: a pinch grows in tiny steps and would get stuck at 1×
        // if this also applied on the way in.
        if factor < 1, next < 1.1 { next = 1 }
        targetZoom = next.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        logZoom.target = log(Double(targetZoom))
        Log.liveZoom.debug(
            "Zoom ×\(Double(factor), format: .fixed(precision: 3)) → \(Double(self.targetZoom), format: .fixed(precision: 2))"
        )
        hud?.show(zoom: targetZoom)
    }

    /// Toggles auto zoom while live zoom is already running (a recording started or stopped).
    func setAutoZoom(_ on: Bool, level: CGFloat) {
        guard isActive, on != autoZoom else { return }
        autoZoom = on
        autoZoomLevel = level.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        if on {
            initialZoom = 1
            lastActivity = CACurrentMediaTime()
            lastMouse = NSEvent.mouseLocation
            startClickMonitors()
        } else {
            initialZoom = autoZoomLevel
            stopClickMonitors()
        }
        if phase == .live { setChrome(opacity: 1) }
    }

    private func startClickMonitors() {
        stopClickMonitors()
        lastActivity = CACurrentMediaTime()
        lastMouse = NSEvent.mouseLocation
        // Clicks pass through the zoom window to the apps below. A listen-only event tap is the
        // primary source because the global NSEvent monitor has been seen to stop delivering clicks
        // mid-recording (macOS 26). Without Accessibility the tap fails and the monitor takes over.
        let tapped = clickTap.start(mask: EventTap.mask(.leftMouseDown), mode: .listenOnly) { [weak self] _, event in
            self?.tappedClick(event)
            return false
        }
        if tapped {
            Log.liveZoom.debug("Click-to-zoom through an event tap")
            return
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.clickArrived(fnHeld: event.modifierFlags.contains(.function))
        }
        if clickMonitor == nil {
            Log.liveZoom.error("Could not install an event tap or a global monitor for clicks")
        }
    }

    private func stopClickMonitors() {
        clickTap.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Clicks on Lupa's own windows (recording bar, camera bubble) never zoom, matching the global
    /// monitor, which does not see them in the first place.
    private func tappedClick(_ event: CGEvent) {
        let mouse = NSEvent.mouseLocation
        let onOwnWindow = NSApp.windows.contains { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(mouse) }
        let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
        guard !onOwnWindow, event.getIntegerValueField(.eventTargetUnixProcessID) != ownPID else { return }
        clickArrived(fnHeld: event.flags.contains(.maskSecondaryFn))
    }

    /// fn-click never zooms: it is the way to click without triggering auto zoom. (⌃-click is not
    /// an option because macOS turns it into a right click.)
    private func clickArrived(fnHeld: Bool) {
        let fnNow =
            NSEvent.modifierFlags.contains(.function)
            || CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        guard !fnHeld, !fnNow else { return }
        handleClick()
    }

    /// Zooms in around the pointer: the clicked point stays under it and the camera centers it.
    private func handleClick() {
        guard isActive, autoZoom, !drawing, phase == .live, let screen,
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        else { return }
        lastActivity = CACurrentMediaTime()
        guard targetZoom < autoZoomLevel else { return }
        targetZoom = autoZoomLevel
        logZoom.target = log(Double(targetZoom))
        Log.liveZoom.debug("Click zoomed to \(Double(self.targetZoom), format: .fixed(precision: 2))")
    }

    /// Mouse idle for `autoZoomIdle` seconds: settle back to 1×.
    private func updateAutoZoom() {
        let now = CACurrentMediaTime()
        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 1 {
            lastMouse = mouse
            lastActivity = now
        }
        if targetZoom > 1, now - lastActivity > Self.autoZoomIdle {
            targetZoom = 1
            logZoom.target = 0
        }
    }

    func setGestureNote(_ note: String?) {
        hud?.note = note
    }

    func reset() {
        guard isActive, phase == .live, !drawing else { return }
        targetZoom = initialZoom
        logZoom.target = log(Double(targetZoom))
        hud?.show(zoom: targetZoom)
    }

    private func present(in window: OverlayWindow, on screen: NSScreen, stream: SCStream, zoom initialZoom: CGFloat) {
        let size = screen.frame.size
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        contentLayer.bounds = view.bounds
        contentLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .linear
        contentLayer.isOpaque = true
        view.layer?.addSublayer(contentLayer)

        // Four thin strips instead of one screen-sized layer: the WindowServer composites every
        // transparent layer on every frame, which is expensive on Retina displays.
        let border = CALayer()
        border.frame = view.bounds
        border.allowsGroupOpacity = false
        border.opacity = 0
        let thickness: CGFloat = 4
        for strip in [
            CGRect(x: 0, y: 0, width: size.width, height: thickness),
            CGRect(x: 0, y: size.height - thickness, width: size.width, height: thickness),
            CGRect(x: 0, y: 0, width: thickness, height: size.height),
            CGRect(x: size.width - thickness, y: 0, width: thickness, height: size.height),
        ] {
            let edge = CALayer()
            edge.frame = strip
            edge.backgroundColor = Theme.lime.cgColor
            border.addSublayer(edge)
        }
        view.layer?.addSublayer(border)
        self.border = border

        let hud = LiveHUDView(frame: view.bounds)
        hud.alphaValue = 0
        view.addSubview(hud)
        self.hud = hud

        window.contentView = view

        self.window = window
        self.stream = stream
        self.screen = screen
        self.initialZoom = initialZoom.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        targetZoom = self.initialZoom
        phase = .waitingForFrame
        isActive = true

        cameraX.snap(to: 0)
        cameraY.snap(to: 0)
        logZoom.snap(to: 0)
        logZoom.target = log(Double(targetZoom))
        applyTransform(in: screen.frame)

        // A display link runs in step with the screen (up to 120 Hz on ProMotion); a 60 Hz Timer
        // drifts against vsync and stutters.
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        let maxFPS = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxFPS, preferred: maxFPS)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil

        // The first frame may already have arrived.
        if contentLayer.contents != nil { beginEntry() }
    }

    private func beginEntry() {
        guard let screen, let view = window?.contentView else { return }
        let prefs = Preferences.shared
        let cursor = LiveCursor(size: prefs.cursorSize, smoothing: prefs.cursorSmoothing)
        view.layer?.addSublayer(cursor.layer)
        cursor.start(at: cursorPoint(in: screen.frame), backingScale: screen.backingScaleFactor)
        self.cursor = cursor
        cursorOnScreen = true
        prefsObserver = prefs.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.cursor?.update(size: prefs.cursorSize, smoothing: prefs.cursorSmoothing)
            }
        }
        // Once the image covers the screen, an opaque window spares the WindowServer from
        // compositing whatever is behind it on every frame. Before the first frame it is clear.
        window?.backgroundColor = .black
        window?.isOpaque = true
        hud?.show(zoom: targetZoom)
        phase = .entering
        phaseStart = CACurrentMediaTime()
    }

    private func cursorPoint(in frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(
            x: (mouse.x - frame.minX).clamped(0, frame.width),
            y: (mouse.y - frame.minY).clamped(0, frame.height)
        )
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let screen else { return }
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { now - $0 } ?? (1.0 / 60)
        lastTimestamp = now
        hud?.tick()
        guard phase != .waitingForFrame else { return }

        let target = cursorPoint(in: screen.frame)
        let onScreen = NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        // Off this display the system cursor comes back; on return, the drawn one reappears in place.
        if onScreen != cursorOnScreen {
            cursorOnScreen = onScreen
            if onScreen {
                SystemCursor.hide()
                cursor?.jump(to: target)
            } else {
                SystemCursor.show()
            }
        }
        let point = cursor?.step(toward: target, visible: onScreen && !drawing) ?? target
        let elapsed = max(0, now - phaseStart)
        let progress = min(1, elapsed / Self.transitionDuration)
        let eased = Self.easeInOut(progress)
        let frame = screen.frame

        switch phase {
        case .waitingForFrame:
            return
        case .entering:
            logZoom.snap(to: log(Double(targetZoom)) * eased)
            // Same rule as the live phase, so the entry ends without a second motion.
            let zoom = exp(logZoom.value)
            cameraX.drive(
                to: Self.cameraTarget(cursor: Double(point.x), length: Double(frame.width), zoom: zoom), dt: dt)
            cameraY.drive(
                to: Self.cameraTarget(cursor: Double(point.y), length: Double(frame.height), zoom: zoom), dt: dt)
            setChrome(opacity: min(1, elapsed / Self.fadeDuration))
            if progress >= 1 { phase = .live }
        case .live:
            if drawing {
                cursor?.place(at: point)
                return
            }
            if autoZoom { updateAutoZoom() }
            let previousZoom = exp(logZoom.value)
            logZoom.step(dt)
            let zoom = exp(logZoom.value)
            Self.move(
                &cameraX, cursor: Double(point.x), length: Double(frame.width), from: previousZoom, to: zoom, dt: dt)
            Self.move(
                &cameraY, cursor: Double(point.y), length: Double(frame.height), from: previousZoom, to: zoom, dt: dt)
        case .leaving:
            logZoom.snap(to: leavingLogZoom * (1 - eased))
            // The cursor glides from where it appears in the magnified image back to the real point.
            let display = CGPoint(
                x: leavingDisplay.x + (point.x - leavingDisplay.x) * eased,
                y: leavingDisplay.y + (point.y - leavingDisplay.y) * eased
            )
            anchorCamera(cursor: point, display: display, frame: frame, dt: dt)
            setChrome(opacity: max(0, 1 - elapsed / Self.fadeDuration))
        }
        applyTransform(in: frame)

        if phase == .leaving, progress >= 1 { stop() }
    }

    /// During transitions the camera is derived directly: the cursor shows at `display` at the current zoom.
    private func anchorCamera(cursor: CGPoint, display: CGPoint, frame: CGRect, dt: Double) {
        let zoom = exp(logZoom.value)
        let limitX = frame.width - frame.width / zoom
        let limitY = frame.height - frame.height / zoom
        cameraX.drive(to: (cursor.x - display.x / zoom).clamped(0, limitX), dt: dt)
        cameraY.drive(to: (cursor.y - display.y / zoom).clamped(0, limitY), dt: dt)
    }

    private func setChrome(opacity: Double) {
        let opacity = autoZoom ? 0 : opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border?.opacity = Float(opacity)
        CATransaction.commit()
        hud?.alphaValue = opacity
    }

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func applyTransform(in frame: CGRect) {
        let zoom = CGFloat(exp(logZoom.value))
        let position = cursor?.position ?? cursorPoint(in: frame)
        let point = CGPoint(x: position.x.clamped(0, frame.width), y: position.y.clamped(0, frame.height))
        let origin = CGPoint(x: cameraX.value, y: cameraY.value)
        // Leave the full-screen layer alone while nothing moves: every change to it makes the
        // WindowServer recomposite the whole screen, which at 60 Hz heats the Mac up for nothing.
        let applied = (zoom, origin)
        if lastApplied.0 != applied.0 || lastApplied.1 != applied.1 {
            lastApplied = applied
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.anchorPoint = .zero
            contentLayer.position = CGPoint(x: -origin.x * zoom, y: -origin.y * zoom)
            contentLayer.transform = CATransform3DMakeScale(zoom, zoom, 1)
            CATransaction.commit()
        }
        // With the camera lagging on its spring, the real point may briefly fall outside the visible span.
        cursor?.place(
            at: CGPoint(
                x: ((point.x - origin.x) * zoom).clamped(0, frame.width),
                y: ((point.y - origin.y) * zoom).clamped(0, frame.height)
            ))
    }

    /// One camera axis. The value is the start of the visible span, in real screen points.
    private static func move(
        _ camera: inout Spring, cursor: Double, length: Double, from previousZoom: Double, to zoom: Double, dt: Double
    ) {
        let visible = length / zoom
        // The spring can dip a hair below 1×, and the range below cannot have a negative bound.
        let limit = max(0, length - visible)
        // When zoom changes, the cursor stays put on screen and the image scales around it.
        let ratio = previousZoom / zoom
        camera.value = (cursor - (cursor - camera.value) * ratio).clamped(0, limit)
        camera.target = cameraTarget(cursor: cursor, length: length, zoom: zoom)
        camera.step(dt)
        let margin = cursorMargin * visible
        camera.confine(to: (cursor - visible + margin)...(cursor - margin))
        camera.confine(to: 0...limit)
    }

    /// Start of the visible span with the cursor centered, pinned to the screen edge when close to it.
    private static func cameraTarget(cursor: Double, length: Double, zoom: Double) -> Double {
        let visible = length / zoom
        return (cursor - visible / 2).clamped(0, length - visible)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let surface = Self.surface(from: sampleBuffer) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.contentLayer.contents = surface
            if self.isActive, self.phase == .waitingForFrame { self.beginEntry() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.stop() }
    }

    private static func surface(from sampleBuffer: CMSampleBuffer) -> IOSurfaceRef? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer,
            let surface = CVPixelBufferGetIOSurface(pixelBuffer)
        else { return nil }
        return surface.takeUnretainedValue()
    }
}
