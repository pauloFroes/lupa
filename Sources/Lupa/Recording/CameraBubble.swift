import AVFoundation
import AppKit

// Bolha da câmera que entra na gravação. Fica acima da sobreposição de zoom e desenho
// (screenSaver + 1) para continuar no vídeo quando você aproxima a tela.
// Quando o mouse de fato vai até a bolha (segue na direção dela, para em cima ou perto dela por
// um instante), ela desliza devagar para o canto oposto; passar por perto não a move. No canto
// oposto ela só sai em dois casos: o mouse vai até ela de novo, ou passaram `awayStay` segundos
// e o mouse está fora da zona que a fez fugir. Segurar ⌥ deixa a bolha parada para arrastar.
final class CameraBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lupa.camera")
    private static let diameter: CGFloat = 220
    private static let margin: CGFloat = 32
    // Só dentro desta distância da borda o movimento do mouse conta como ir até a bolha.
    private static let approachDistance: CGFloat = 90
    // Parado (ou quase) a esta distância da borda, o mouse também quer o lugar dela.
    private static let restDistance: CGFloat = 30
    // A intenção precisa durar isto para a bolha se mexer: uma passada rápida não conta.
    private static let intentHold: CFTimeInterval = 0.3
    // No lugar de fuga a bolha fica pelo menos isto. Antes disso só sai se o mouse for até ela.
    private static let awayStay: CFTimeInterval = 8
    // Depois desse tempo, volta se o mouse estiver além desta distância do lugar original
    // (fora da zona que a fez fugir) por `returnHold`.
    private static let returnDistance: CGFloat = 200
    private static let returnHold: CFTimeInterval = 1.0

    private var screen: NSScreen?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    // Lugar escolhido (origem da janela); muda quando você arrasta a bolha.
    private var home: CGPoint = .zero
    private var isAway = false
    // Mais lenta que o cursor: a bolha desliza, não salta.
    private var springX = Spring(value: 0, response: 0.9)
    private var springY = Spring(value: 0, response: 0.9)
    private var mouseVelocity = CGVector.zero
    private var lastMouse: CGPoint?
    private var intentSince: CFTimeInterval?
    private var clearSince: CFTimeInterval?
    private var movedAt: CFTimeInterval = 0
    private var lastSetOrigin: CGPoint = .zero
    private var isDragging = false

    func show(on screen: NSScreen) throws {
        guard panel == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()

        let size = Self.diameter
        let frame = NSRect(
            x: screen.visibleFrame.maxX - size - Self.margin,
            y: screen.visibleFrame.minY + Self.margin,
            width: size,
            height: size
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

        let session = session
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
            session.inputs.forEach { session.removeInput($0) }
        }
    }

    // MARK: - Desvio do mouse

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

        // Arrasto: a janela se move sozinha; ao soltar, o novo lugar vira o lugar da bolha.
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed {
            if !isDragging, !panel.ignoresMouseEvents, panel.frame.contains(mouse) { isDragging = true }
            if isDragging { return }
        } else if isDragging {
            isDragging = false
            let origin = clamped(panel.frame.origin)
            home = origin
            isAway = false
            springX.snap(to: origin.x)
            springY.snap(to: origin.y)
            setOrigin(origin)
            return
        }
        // Se algo moveu a janela por fora, adota a posição sem brigar.
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

        // Enquanto desliza, o clique passa para o app embaixo, e ela não é agarrada no meio do caminho.
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
        // Média móvel de ~80 ms: tira o tremor sem atrasar a leitura da direção.
        let a = CGFloat(1 - exp(-dt / 0.08))
        mouseVelocity.dx += (instant.dx - mouseVelocity.dx) * a
        mouseVelocity.dy += (instant.dy - mouseVelocity.dy) * a
    }

    private func decide(mouse: CGPoint, away: CGPoint, now: CFTimeInterval) {
        let occupied = isAway ? away : home
        let other = isAway ? home : away
        let stayedLongEnough = now - movedAt > Self.awayStay

        // O mouse quer o lugar onde a bolha está agora: ela vai para o outro, se ele estiver livre.
        if wantsSpot(mouse: mouse, bubbleAt: occupied), distance(from: mouse, toBubbleAt: other) > Self.approachDistance {
            let since = intentSince ?? now
            intentSince = since
            if now - since >= Self.intentHold { move(away: !isAway, now: now) }
        } else {
            intentSince = nil
        }

        // Fora do lugar, só volta sozinha depois de `awayStay` e com o mouse fora da zona original.
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

    // Intenção de ir até a bolha: em cima dela, parado bem perto, ou vindo na direção dela.
    private func wantsSpot(mouse: CGPoint, bubbleAt origin: CGPoint) -> Bool {
        let d = distance(from: mouse, toBubbleAt: origin)
        if d > Self.approachDistance { return false }
        let speed = hypot(mouseVelocity.dx, mouseVelocity.dy)
        // Cruzando a bolha depressa é passagem, não intenção.
        if d <= 0 { return speed < 600 }
        if speed < 60 { return d < Self.restDistance }
        let radius = Self.diameter / 2
        let center = CGPoint(x: origin.x + radius, y: origin.y + radius)
        let toCenter = CGVector(dx: center.x - mouse.x, dy: center.y - mouse.y)
        let length = max(1, hypot(toCenter.dx, toCenter.dy))
        let heading = (mouseVelocity.dx * toCenter.dx + mouseVelocity.dy * toCenter.dy) / (speed * length)
        // Seguindo assim por 0,3 s, o mouse chega à bolha.
        let ahead = CGPoint(x: mouse.x + mouseVelocity.dx * 0.3, y: mouse.y + mouseVelocity.dy * 0.3)
        return heading > 0.6 && distance(from: ahead, toBubbleAt: origin) < d
    }

    private func setOrigin(_ origin: CGPoint) {
        lastSetOrigin = origin
        if panel?.frame.origin != origin { panel?.setFrameOrigin(origin) }
    }

    // Distância do mouse até a borda da bolha com origem em `origin` (negativa dentro dela).
    private func distance(from mouse: CGPoint, toBubbleAt origin: CGPoint) -> CGFloat {
        let radius = Self.diameter / 2
        let center = CGPoint(x: origin.x + radius, y: origin.y + radius)
        return hypot(mouse.x - center.x, mouse.y - center.y) - radius
    }

    // Lugar de fuga: espelho do lugar original no lado mais distante da tela.
    private func awayOrigin() -> CGPoint {
        guard let frame = screen?.visibleFrame else { return home }
        let size = Self.diameter
        let mirroredX = frame.minX + frame.maxX - size - home.x
        let mirroredY = frame.minY + frame.maxY - size - home.y
        let dx = abs(mirroredX - home.x)
        let dy = abs(mirroredY - home.y)
        let point = dx >= size + Self.approachDistance || dx >= dy
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
