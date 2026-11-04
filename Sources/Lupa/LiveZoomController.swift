import AppKit
import CoreMedia
import ScreenCaptureKit

// Zoom ao vivo: um SCStream da tela (sem as janelas da Lupa) desenhado numa janela que não
// recebe clique. Como a escala é em torno do cursor, o clique cai no ponto real sob o mouse.
final class LiveZoomController: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isActive = false
    var onStop: (() -> Void)?

    private var window: OverlayWindow?
    private var stream: SCStream?
    private var screen: NSScreen?
    private var ticker: Timer?
    private var zoom: CGFloat = 1
    private var targetZoom: CGFloat = 2
    private var initialZoom: CGFloat = 2
    private var hud: LiveHUDView?
    private let contentLayer = CALayer()
    static let zoomRange: ClosedRange<CGFloat> = 1.25 ... 8
    private let queue = DispatchQueue(label: "lupa.live-zoom")

    func start(on screen: NSScreen, zoom initialZoom: CGFloat) async throws {
        // A janela vazia entra na tela antes do filtro, então a Lupa com certeza está na lista
        // de apps que o filtro exclui.
        let window = await MainActor.run { () -> OverlayWindow in
            let window = OverlayWindow(screen: screen)
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            return window
        }
        do {
            let filter = try await ScreenCapture.filter(for: screen, requireExclusion: true)
            let configuration = ScreenCapture.configuration(for: screen)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 5
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            await MainActor.run {
                self.present(in: window, on: screen, stream: stream, zoom: initialZoom)
            }
        } catch {
            await MainActor.run { window.orderOut(nil) }
            throw error
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        ticker?.invalidate()
        ticker = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        window?.orderOut(nil)
        window = nil
        hud = nil
        contentLayer.contents = nil
        contentLayer.removeFromSuperlayer()
        onStop?()
    }

    func adjust(by factor: CGFloat) {
        guard isActive else { return }
        targetZoom = (targetZoom * factor).clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        hud?.show(zoom: targetZoom)
    }

    func reset() {
        guard isActive else { return }
        targetZoom = initialZoom
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
        view.layer?.addSublayer(contentLayer)

        let border = CALayer()
        border.frame = view.bounds
        border.borderColor = Theme.lime.cgColor
        border.borderWidth = 4
        view.layer?.addSublayer(border)

        let hud = LiveHUDView(frame: view.bounds)
        view.addSubview(hud)
        self.hud = hud

        window.contentView = view

        self.window = window
        self.stream = stream
        self.screen = screen
        zoom = 1
        self.initialZoom = initialZoom.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        targetZoom = self.initialZoom
        isActive = true
        hud.show(zoom: targetZoom)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.updateTransform() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func updateTransform() {
        guard let screen else { return }
        hud?.tick()
        zoom += (targetZoom - zoom) * 0.2
        if abs(targetZoom - zoom) < 0.002 { zoom = targetZoom }
        let frame = screen.frame
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(
            x: (mouse.x - frame.minX).clamped(0, frame.width),
            y: (mouse.y - frame.minY).clamped(0, frame.height)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.anchorPoint = CGPoint(x: point.x / frame.width, y: point.y / frame.height)
        contentLayer.position = point
        contentLayer.transform = CATransform3DMakeScale(zoom, zoom, 1)
        CATransaction.commit()
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

// Selo "AO VIVO" com o nível do zoom, sempre visível, e a barra de comandos, que aparece ao
// ligar e a cada mudança de zoom e some sozinha.
private final class LiveHUDView: NSView {
    private var zoom: CGFloat = 2
    private var hintsUntil = Date.distantPast

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(zoom: CGFloat) {
        self.zoom = zoom
        hintsUntil = Date().addingTimeInterval(3)
        needsDisplay = true
    }

    func tick() {
        if Date() < hintsUntil.addingTimeInterval(0.4) { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let level = String(format: "%.1f×", zoom).replacingOccurrences(of: ".", with: ",")
        HUD.drawBadgeRow(label: "AO VIVO", value: level, origin: CGPoint(x: 24, y: bounds.height - 24 - 36))
        HUD.drawBar(
            [
                .badge(level),
                HUD.hint("⌃=  ⌃-", "zoom"),
                HUD.hint("⌃ rolar", "zoom"),
                HUD.hint("⌃0", "volta ao inicial"),
                HUD.hint("esc", "sai"),
            ],
            style: .primary,
            centerX: bounds.midX,
            bottom: 40,
            maxWidth: bounds.width - 32,
            alpha: HUD.fadeAlpha(until: hintsUntil)
        )
    }
}
