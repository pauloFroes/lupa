import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit

// Zoom ao vivo: um SCStream da tela (sem as janelas da Lupa) desenhado numa janela que não
// recebe clique. A câmera acompanha o cursor (LiveCursor, que segue o mouse com uma mola) a todo
// momento e chega à borda da tela antes dele. Encostada, ela para e só o cursor anda até a
// borda. O cursor é desenhado onde o ponto real do mouse
// aparece na imagem ampliada, então, parado, o clique cai exatamente no que está sob ele.
// A entrada espera o primeiro quadro, para começar em 1× idêntica à tela, e a saída faz o caminho
// inverso pela mesma curva.
final class LiveZoomController: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isActive = false
    var onStop: (() -> Void)?

    private var window: OverlayWindow?
    private var stream: SCStream?
    private var screen: NSScreen?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private enum Phase { case waitingForFrame, entering, live, leaving }
    private var phase = Phase.waitingForFrame
    private var phaseStart: CFTimeInterval = 0
    private var leavingLogZoom = 0.0
    private var leavingDisplay = CGPoint.zero
    private var border: CALayer?
    // O zoom anda em escala logarítmica: 2× → 4× leva o mesmo tempo que 4× → 8×, como o olho espera.
    private var logZoom = Spring(value: 0, response: 0.42)
    private var cameraX = Spring(value: 0, response: 0.22)
    private var cameraY = Spring(value: 0, response: 0.22)
    private var cursor: LiveCursor?
    private var cursorOnScreen = true
    private var prefsObserver: AnyCancellable?
    private var targetZoom: CGFloat = 2
    private var initialZoom: CGFloat = 2
    private var hud: LiveHUDView?
    private let contentLayer = CALayer()
    static let zoomRange: ClosedRange<CGFloat> = 1 ... 8
    // Quanto a câmera se adianta rumo à borda: 0 só mostra a borda com o mouse nela; 1 mantém o
    // cursor no centro até a câmera encostar. Abaixo de 1 para o zoom 1× não dividir por 0.
    static let edgeReach = 0.85
    static let transitionDuration = 0.7
    static let fadeDuration = 0.3
    private let queue = DispatchQueue(label: "lupa.live-zoom")

    func start(on screen: NSScreen, zoom initialZoom: CGFloat) async throws {
        // A janela vazia entra na tela antes do filtro, então a Lupa com certeza está na lista
        // de apps que o filtro exclui.
        let window = await MainActor.run { () -> OverlayWindow in
            contentLayer.contents = nil
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
        phase = .waitingForFrame
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
        onStop?()
    }

    func adjust(by factor: CGFloat) {
        guard isActive, phase == .live else { return }
        var next = targetZoom * factor
        // Só ao diminuir: a pinça sobe em passos pequenos e ficaria presa em 1× se isto valesse na subida.
        if factor < 1, next < 1.1 { next = 1 }
        targetZoom = next.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        logZoom.target = log(Double(targetZoom))
        NSLog("Lupa zoom ao vivo: fator %.3f, zoom %.2f", factor, targetZoom)
        hud?.show(zoom: targetZoom)
    }

    func setGestureNote(_ note: String?) {
        hud?.note = note
        hud?.needsDisplay = true
    }

    func reset() {
        guard isActive, phase == .live else { return }
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
        border.opacity = 0
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

        // O display link acompanha a tela (120 Hz no ProMotion); o Timer de 60 Hz batia fora do
        // vsync e dava os trancos.
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        let maxFPS = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxFPS, preferred: maxFPS)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil

        // O primeiro quadro pode ter chegado antes daqui.
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
        // Fora desta tela o cursor do sistema volta; ao voltar, o desenhado reaparece no lugar.
        if onScreen != cursorOnScreen {
            cursorOnScreen = onScreen
            if onScreen {
                SystemCursor.hide()
                cursor?.jump(to: target)
            } else {
                SystemCursor.show()
            }
        }
        let point = cursor?.step(toward: target, visible: onScreen) ?? target
        let elapsed = max(0, now - phaseStart)
        let progress = min(1, elapsed / Self.transitionDuration)
        let eased = Self.easeInOut(progress)
        let frame = screen.frame

        switch phase {
        case .waitingForFrame:
            return
        case .entering:
            logZoom.snap(to: log(Double(targetZoom)) * eased)
            // Pela mesma regra do modo ao vivo, para a entrada terminar sem um segundo movimento.
            let zoom = exp(logZoom.value)
            cameraX.drive(to: Self.cameraTarget(cursor: Double(point.x), length: Double(frame.width), zoom: zoom), dt: dt)
            cameraY.drive(to: Self.cameraTarget(cursor: Double(point.y), length: Double(frame.height), zoom: zoom), dt: dt)
            setChrome(opacity: min(1, elapsed / Self.fadeDuration))
            if progress >= 1 { phase = .live }
        case .live:
            let previousZoom = exp(logZoom.value)
            logZoom.step(dt)
            let zoom = exp(logZoom.value)
            Self.move(&cameraX, cursor: Double(point.x), length: Double(frame.width), from: previousZoom, to: zoom, dt: dt)
            Self.move(&cameraY, cursor: Double(point.y), length: Double(frame.height), from: previousZoom, to: zoom, dt: dt)
        case .leaving:
            logZoom.snap(to: leavingLogZoom * (1 - eased))
            // O cursor volta do ponto em que aparece na imagem ampliada para o ponto real.
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

    // Nas transições a câmera sai direto da regra: o cursor aparece em `display` no zoom atual.
    private func anchorCamera(cursor: CGPoint, display: CGPoint, frame: CGRect, dt: Double) {
        let zoom = exp(logZoom.value)
        let limitX = frame.width - frame.width / zoom
        let limitY = frame.height - frame.height / zoom
        cameraX.drive(to: (cursor.x - display.x / zoom).clamped(0, limitX), dt: dt)
        cameraY.drive(to: (cursor.y - display.y / zoom).clamped(0, limitY), dt: dt)
    }

    private func setChrome(opacity: Double) {
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.anchorPoint = .zero
        contentLayer.position = CGPoint(x: -origin.x * zoom, y: -origin.y * zoom)
        contentLayer.transform = CATransform3DMakeScale(zoom, zoom, 1)
        CATransaction.commit()
        // Com a câmera atrasada na mola, o ponto real pode cair um instante fora do trecho visível.
        cursor?.place(at: CGPoint(
            x: ((point.x - origin.x) * zoom).clamped(0, frame.width),
            y: ((point.y - origin.y) * zoom).clamped(0, frame.height)
        ))
    }

    // Um eixo da câmera; o valor é o início do trecho visível, em pontos da tela real.
    private static func move(_ camera: inout Spring, cursor: Double, length: Double, from previousZoom: Double, to zoom: Double, dt: Double) {
        let visible = length / zoom
        let limit = length - visible
        // Ao mudar o zoom, o cursor fica onde está na tela e a imagem cresce em torno dele.
        let ratio = previousZoom / zoom
        camera.value = (cursor - (cursor - camera.value) * ratio).clamped(0, limit)
        camera.target = cameraTarget(cursor: cursor, length: length, zoom: zoom)
        camera.step(dt)
        camera.value = camera.value.clamped(0, limit)
    }

    // Início do trecho visível para o cursor num eixo. Dentro de `margin` da borda a câmera já
    // encostou; entre as margens ela percorre todo o resto, sempre com o cursor no trecho.
    private static func cameraTarget(cursor: Double, length: Double, zoom: Double) -> Double {
        let visible = length / zoom
        let margin = edgeReach * visible / 2
        let progress = ((cursor - margin) / (length - 2 * margin)).clamped(0, 1)
        return progress * (length - visible)
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
