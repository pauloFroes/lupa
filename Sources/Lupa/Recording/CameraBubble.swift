import AVFoundation
import AppKit

// Bolha da câmera que entra na gravação. Fica acima da sobreposição de zoom e desenho
// (screenSaver + 1) para continuar no vídeo quando você aproxima a tela.
// Quando o mouse chega perto, a bolha desliza para o canto oposto e volta ao lugar dela
// quando o mouse se afasta. Segurar ⌥ deixa a bolha parada para arrastar.
final class CameraBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lupa.camera")
    private static let diameter: CGFloat = 220
    private static let margin: CGFloat = 32
    // Distância do mouse à borda da bolha que a faz desviar.
    private static let dodgeDistance: CGFloat = 60
    // O mouse precisa se afastar mais que isso da borda do lugar original para ela voltar.
    private static let returnDistance: CGFloat = 140

    private var screen: NSScreen?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    // Lugar escolhido (origem da janela); muda quando você arrasta a bolha.
    private var home: CGPoint = .zero
    private var isAway = false
    private var springX = Spring(value: 0, response: 0.45)
    private var springY = Spring(value: 0, response: 0.45)
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
            if !isDragging, panel.frame.contains(mouse) { isDragging = true }
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

        let holdingOption = NSEvent.modifierFlags.contains(.option)
        let away = awayOrigin()
        if !holdingOption {
            if isAway {
                if distance(from: mouse, toBubbleAt: home) > Self.returnDistance {
                    isAway = false
                } else if distance(from: mouse, toBubbleAt: away) < Self.dodgeDistance {
                    // O mouse foi atrás dela: volta ao lugar original.
                    isAway = false
                }
            } else if distance(from: mouse, toBubbleAt: home) < Self.dodgeDistance,
                      distance(from: mouse, toBubbleAt: away) > Self.dodgeDistance {
                isAway = true
            }
        }

        let target = isAway ? away : home
        springX.target = target.x
        springY.target = target.y
        guard !(springX.isSettled && springY.isSettled && panel.frame.origin == target) else { return }
        springX.step(dt)
        springY.step(dt)
        setOrigin(CGPoint(x: springX.value.rounded(), y: springY.value.rounded()))
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
        let point = dx >= size + Self.dodgeDistance || dx >= dy
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
