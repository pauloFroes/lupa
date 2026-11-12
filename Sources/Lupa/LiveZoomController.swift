import AppKit
import Combine
import CoreMedia
import OSLog
import ScreenCaptureKit

// Zoom ao vivo: um SCStream da tela (sem as janelas da Lupa) desenhado numa janela que não
// recebe clique. A câmera persegue o cursor (LiveCursor, que segue o mouse com uma mola) para
// centralizá-lo, com um leve atraso, e chega à borda da tela antes dele. Encostada, ela para e só
// o cursor anda até a borda. O cursor é desenhado onde o ponto real do mouse aparece na imagem
// ampliada, então, parado, o clique cai exatamente no que está sob ele.
// A entrada espera o primeiro quadro, para começar em 1× idêntica à tela, e a saída faz o caminho
// inverso pela mesma curva.
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
    // O zoom anda em escala logarítmica: 2× → 4× leva o mesmo tempo que 4× → 8×, como o olho espera.
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
    static let zoomRange: ClosedRange<CGFloat> = 1 ... 8
    // Fração do trecho visível, em cada lado, que o cursor nunca invade por atraso da câmera.
    static let cursorMargin = 0.1
    static let transitionDuration = 0.7
    static let fadeDuration = 0.3
    private let queue = DispatchQueue(label: "lupa.live-zoom")
    // Console › processo Lupa › categoria "zoom-clique": diz se o clique chegou e o que o barrou.
    static let clickLog = Logger(subsystem: "io.github.paulofroes.lupa", category: "zoom-clique")

    // Gravação: o Ao vivo começa em 1×, aproxima no ponto do clique e volta a 1× quando o mouse
    // fica parado, como nos vídeos editados. Sem borda nem selo, que entrariam no vídeo.
    private(set) var autoZoom = false
    private var autoZoomLevel: CGFloat = 2
    private var clickMonitors: [Any] = []
    private var lastActivity: CFTimeInterval = 0
    private var lastMouse = CGPoint.zero
    static let autoZoomIdle: CFTimeInterval = 2.5

    // Desenho ao vivo: a imagem continua chegando, mas a câmera e o zoom param onde estão, para o
    // traço ficar sobre o mesmo ponto do conteúdo. O cursor desenhado some (a caneta é o cursor).
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

    func start(on screen: NSScreen, zoom initialZoom: CGFloat, autoZoom: Bool = false) async throws {
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
                self.autoZoom = autoZoom
                self.autoZoomLevel = initialZoom.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
                self.present(in: window, on: screen, stream: stream, zoom: autoZoom ? 1 : initialZoom)
                if autoZoom { self.startClickMonitors() }
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
        // Só ao diminuir: a pinça sobe em passos pequenos e ficaria presa em 1× se isto valesse na subida.
        if factor < 1, next < 1.1 { next = 1 }
        targetZoom = next.clamped(Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        logZoom.target = log(Double(targetZoom))
        NSLog("Lupa zoom ao vivo: fator %.3f, zoom %.2f", factor, targetZoom)
        hud?.show(zoom: targetZoom)
    }

    // Liga ou desliga o zoom automático com o Ao vivo já aberto (a gravação começou ou terminou).
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
        // O clique passa pela janela do zoom e vai para os apps; o monitor global o enxerga.
        // Cliques nas janelas da própria Lupa (barra de gravação, bolha) não dão zoom.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            // fn+clique não aproxima: é o jeito de clicar sem disparar o zoom automático.
            // (⌃+clique abriria o menu de contexto no macOS.)
            let fnEvent = event.modifierFlags.contains(.function)
            let fnNow = NSEvent.modifierFlags.contains(.function)
            let fnState = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
            Self.clickLog.notice("clique recebido (fn: evento \(fnEvent), agora \(fnNow), estado \(fnState))")
            if fnEvent || fnNow || fnState { return }
            self?.handleClick()
        }) {
            clickMonitors.append(global)
            Self.clickLog.notice("monitor de clique ligado (acessibilidade: \(AXIsProcessTrusted()))")
        } else {
            Self.clickLog.error("monitor de clique não foi criado pelo macOS")
        }
    }

    private func stopClickMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
    }

    // O clique aproxima em torno do cursor: o ponto clicado fica sob ele e a câmera o centraliza.
    private func handleClick() {
        guard isActive, autoZoom, !drawing, phase == .live, let screen,
              NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) else {
            Self.clickLog.notice("clique ignorado (ativo \(self.isActive), auto \(self.autoZoom), desenho \(self.drawing), fase \(String(describing: self.phase), privacy: .public), na tela \(self.screen.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false))")
            return
        }
        lastActivity = CACurrentMediaTime()
        guard targetZoom < autoZoomLevel else {
            Self.clickLog.notice("clique já em zoom (\(Double(self.targetZoom)) de \(Double(self.autoZoomLevel)))")
            return
        }
        targetZoom = autoZoomLevel
        logZoom.target = log(Double(targetZoom))
        Self.clickLog.notice("clique deu zoom \(Double(self.targetZoom))")
    }

    // Mouse parado por `autoZoomIdle` segundos: volta a 1×.
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
            NSLog("Lupa gravação: mouse parado, volta a 1×")
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

        // Quatro filetes em vez de uma camada do tamanho da tela: o WindowServer mistura cada
        // camada transparente a cada quadro, e isso pesa em tela Retina.
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
        // Com a imagem cobrindo a tela, a janela opaca poupa o WindowServer de compor o que está
        // atrás a cada quadro; era o que dava os trancos. Antes do primeiro quadro ela é transparente.
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
            // Pela mesma regra do modo ao vivo, para a entrada terminar sem um segundo movimento.
            let zoom = exp(logZoom.value)
            cameraX.drive(to: Self.cameraTarget(cursor: Double(point.x), length: Double(frame.width), zoom: zoom), dt: dt)
            cameraY.drive(to: Self.cameraTarget(cursor: Double(point.y), length: Double(frame.height), zoom: zoom), dt: dt)
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
        // Parado, a camada da tela inteira não é tocada: cada mudança nela faz o WindowServer
        // recompor a tela toda, e isso, 60 vezes por segundo, aquece o Mac à toa.
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
        // Com a câmera atrasada na mola, o ponto real pode cair um instante fora do trecho visível.
        cursor?.place(at: CGPoint(
            x: ((point.x - origin.x) * zoom).clamped(0, frame.width),
            y: ((point.y - origin.y) * zoom).clamped(0, frame.height)
        ))
    }

    // Um eixo da câmera; o valor é o início do trecho visível, em pontos da tela real.
    private static func move(_ camera: inout Spring, cursor: Double, length: Double, from previousZoom: Double, to zoom: Double, dt: Double) {
        let visible = length / zoom
        // A mola pode passar de 1× por um fio, e a faixa abaixo não aceita limite negativo.
        let limit = max(0, length - visible)
        // Ao mudar o zoom, o cursor fica onde está na tela e a imagem cresce em torno dele.
        let ratio = previousZoom / zoom
        camera.value = (cursor - (cursor - camera.value) * ratio).clamped(0, limit)
        camera.target = cameraTarget(cursor: cursor, length: length, zoom: zoom)
        camera.step(dt)
        let margin = cursorMargin * visible
        camera.confine(to: (cursor - visible + margin) ... (cursor - margin))
        camera.confine(to: 0 ... limit)
    }

    // Início do trecho visível com o cursor no centro; perto da borda da tela, encosta nela.
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

// Selo "AO VIVO" com o nível do zoom, sempre visível, e a barra de comandos, que aparece ao
// ligar e a cada mudança de zoom e some sozinha.
private final class LiveHUDView: NSView {
    private var zoom: CGFloat = 2
    private var hintsUntil = Date.distantPast
    var note: String? {
        didSet { bar.needsDisplay = true }
    }
    // Duas áreas pequenas: uma camada transparente do tamanho da tela custaria a cada quadro.
    private let badge = HUDPart()
    private let bar = HUDPart()

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.frame = NSRect(x: 0, y: frame.height - 100, width: 360, height: 100)
        bar.frame = NSRect(x: 0, y: 0, width: frame.width, height: 170)
        badge.onDraw = { [weak self] bounds in self?.drawBadge(in: bounds) }
        bar.onDraw = { [weak self] bounds in self?.drawHints(in: bounds) }
        addSubview(badge)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(zoom: CGFloat) {
        self.zoom = zoom
        hintsUntil = Date().addingTimeInterval(3)
        bar.isHidden = false
        badge.needsDisplay = true
        bar.needsDisplay = true
    }

    func tick() {
        guard !bar.isHidden else { return }
        if Date() < hintsUntil.addingTimeInterval(0.4) {
            bar.needsDisplay = true
        } else {
            bar.isHidden = true
        }
    }

    private var level: String {
        String(format: "%.1f×", zoom).replacingOccurrences(of: ".", with: ",")
    }

    private func drawBadge(in bounds: NSRect) {
        HUD.drawBadgeRow(label: "AO VIVO", value: level, origin: CGPoint(x: 24, y: bounds.height - 24 - 36))
    }

    private func drawHints(in bounds: NSRect) {
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

private final class HUDPart: NSView {
    var onDraw: ((NSRect) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        onDraw?(bounds)
    }
}
