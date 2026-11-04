import AppKit
import CoreMedia
import ScreenCaptureKit

// Zoom ao vivo: um SCStream da tela (sem as janelas da Lupa) desenhado numa janela que não
// recebe clique. A escala é em torno de um ponto que segue o cursor por uma mola: em movimento
// ele fica um instante atrás (a fluidez do Screen Studio) e, parado, coincide com o cursor,
// então o clique cai no ponto real sob o mouse.
final class LiveZoomController: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isActive = false
    var onStop: (() -> Void)?

    private var window: OverlayWindow?
    private var stream: SCStream?
    private var screen: NSScreen?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var closing = false
    // O zoom anda em escala logarítmica: 2× → 4× leva o mesmo tempo que 4× → 8×, como o olho espera.
    private var logZoom = Spring(value: 0, response: 0.42)
    private var focusX = Spring(value: 0, response: 0.26)
    private var focusY = Spring(value: 0, response: 0.26)
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
            let fps = Int32(max(60, screen.maximumFramesPerSecond))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: fps)
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

    // Animado, o zoom volta a 1× pela mola antes de fechar, como a câmera saindo do zoom.
    func stop(animated: Bool = false) {
        guard isActive else { return }
        if animated, displayLink != nil {
            guard !closing else { return }
            closing = true
            logZoom.target = 0
            return
        }
        isActive = false
        closing = false
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
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
        guard isActive, !closing else { return }
        targetZoom = (targetZoom * factor).clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        logZoom.target = log(Double(targetZoom))
        NSLog("Lupa zoom ao vivo: fator %.3f, zoom %.2f", factor, targetZoom)
        hud?.show(zoom: targetZoom)
    }

    func setGestureNote(_ note: String?) {
        hud?.note = note
        hud?.needsDisplay = true
    }

    func reset() {
        guard isActive, !closing else { return }
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
        self.initialZoom = initialZoom.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        targetZoom = self.initialZoom
        closing = false
        isActive = true
        hud.show(zoom: targetZoom)

        let cursor = cursorPoint(in: screen.frame)
        focusX.snap(to: Double(cursor.x))
        focusY.snap(to: Double(cursor.y))
        logZoom.snap(to: 0)
        logZoom.target = log(Double(targetZoom))
        applyTransform(in: screen.frame)

        // O display link acompanha a tela (120 Hz no ProMotion); o Timer de 60 Hz batia fora do
        // vsync e dava os trancos.
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        let maxFPS = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxFPS, preferred: maxFPS)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
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

        let cursor = cursorPoint(in: screen.frame)
        focusX.target = Double(cursor.x)
        focusY.target = Double(cursor.y)
        focusX.step(dt)
        focusY.step(dt)
        logZoom.step(dt)
        applyTransform(in: screen.frame)

        if closing, logZoom.value < 0.01 { stop() }
    }

    private func applyTransform(in frame: CGRect) {
        let zoom = CGFloat(exp(logZoom.value))
        let focus = CGPoint(
            x: CGFloat(focusX.value).clamped(0, frame.width),
            y: CGFloat(focusY.value).clamped(0, frame.height)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.anchorPoint = CGPoint(x: focus.x / frame.width, y: focus.y / frame.height)
        contentLayer.position = focus
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
    var note: String?

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
                HUD.hint("pinça", "zoom"),
                HUD.hint("⌃ rolar", "zoom"),
                HUD.hint("⌃+  ⌃-", "zoom"),
                HUD.hint("⌃0", "volta ao inicial"),
                HUD.hint("esc", "sai"),
            ],
            style: .primary,
            centerX: bounds.midX,
            bottom: 40,
            maxWidth: bounds.width - 32,
            alpha: HUD.fadeAlpha(until: hintsUntil)
        )
        if let note {
            HUD.drawBar(
                [.hint([(note, false)])],
                style: .secondary,
                centerX: bounds.midX,
                bottom: 104,
                maxWidth: bounds.width - 32,
                alpha: HUD.fadeAlpha(until: hintsUntil)
            )
        }
    }
}
