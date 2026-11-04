import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit

// Zoom ao vivo: um SCStream da tela (sem as janelas da Lupa) desenhado numa janela que não
// recebe clique. A escala é em torno do cursor desenhado pela Lupa (LiveCursor), que segue o
// mouse com uma mola; parado, ele coincide com o mouse e o clique cai no ponto certo.
final class LiveZoomController: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isActive = false
    var onStop: (() -> Void)?

    private var window: OverlayWindow?
    private var stream: SCStream?
    private var screen: NSScreen?
    private var ticker: Timer?
    private var zoom: CGFloat = 1
    private var targetZoom: CGFloat = 2
    private let contentLayer = CALayer()
    private var cursor: LiveCursor?
    private var cursorOnScreen = true
    private var prefsObserver: AnyCancellable?
    private let queue = DispatchQueue(label: "lupa.live-zoom")

    func start(on screen: NSScreen, zoom initialZoom: CGFloat) async throws {
        let filter = try await ScreenCapture.filter(for: screen)
        let configuration = ScreenCapture.configuration(for: screen)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        await MainActor.run {
            self.present(on: screen, stream: stream, zoom: initialZoom)
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        ticker?.invalidate()
        ticker = nil
        prefsObserver = nil
        cursor?.stop()
        cursor = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        window?.orderOut(nil)
        window = nil
        contentLayer.contents = nil
        contentLayer.removeFromSuperlayer()
        onStop?()
    }

    func adjust(by factor: CGFloat) {
        targetZoom = (targetZoom * factor).clamped(1.25, 16)
    }

    private func present(on screen: NSScreen, stream: SCStream, zoom initialZoom: CGFloat) {
        let window = OverlayWindow(screen: screen)
        window.ignoresMouseEvents = true

        let size = screen.frame.size
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        contentLayer.bounds = view.bounds
        contentLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .linear
        view.layer?.addSublayer(contentLayer)

        let border = CALayer()
        border.frame = view.bounds
        border.borderColor = Theme.lime.cgColor
        border.borderWidth = 4
        view.layer?.addSublayer(border)

        let prefs = Preferences.shared
        let cursor = LiveCursor(size: prefs.cursorSize, smoothing: prefs.cursorSmoothing)
        view.layer?.addSublayer(cursor.layer)
        cursor.start(at: localMouse(in: screen.frame), backingScale: screen.backingScaleFactor)
        self.cursor = cursor
        cursorOnScreen = true
        prefsObserver = prefs.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.cursor?.update(size: prefs.cursorSize, smoothing: prefs.cursorSmoothing)
            }
        }

        let badge = LiveBadgeView(frame: NSRect(x: 24, y: size.height - 24 - 32, width: 104, height: 32))
        view.addSubview(badge)

        window.contentView = view
        window.orderFrontRegardless()

        self.window = window
        self.stream = stream
        self.screen = screen
        zoom = 1
        targetZoom = initialZoom
        isActive = true

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.updateTransform() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func updateTransform() {
        guard let screen else { return }
        zoom += (targetZoom - zoom) * 0.2
        let frame = screen.frame
        let raw = localMouse(in: frame)
        let onScreen = NSMouseInRect(NSEvent.mouseLocation, frame, false)
        let target = CGPoint(x: raw.x.clamped(0, frame.width), y: raw.y.clamped(0, frame.height))
        var point = target
        if let cursor {
            // Fora desta tela o cursor do sistema volta; ao voltar, o desenhado reaparece no lugar.
            if onScreen != cursorOnScreen {
                cursorOnScreen = onScreen
                if onScreen {
                    SystemCursor.hide()
                    cursor.jump(to: target)
                } else {
                    SystemCursor.show()
                }
            }
            let smoothed = cursor.step(toward: target, visible: onScreen)
            point = CGPoint(x: smoothed.x.clamped(0, frame.width), y: smoothed.y.clamped(0, frame.height))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.anchorPoint = CGPoint(x: point.x / frame.width, y: point.y / frame.height)
        contentLayer.position = point
        contentLayer.transform = CATransform3DMakeScale(zoom, zoom, 1)
        CATransaction.commit()
    }

    private func localMouse(in frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let surface = Self.surface(from: sampleBuffer) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.contentLayer.contents = surface
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

private final class LiveBadgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.lime.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        Theme.ink1000.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: bounds.midY - 4, width: 8, height: 8)).fill()
        let label = NSAttributedString(string: "AO VIVO", attributes: [
            .font: Theme.mono(12, .semibold),
            .foregroundColor: Theme.ink1000,
            .kern: 1.2,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: 28, y: bounds.midY - size.height / 2))
    }
}
