import AVFoundation
import AppKit

// Bolha da câmera que entra na gravação. Fica acima da sobreposição de zoom e desenho
// (screenSaver + 1) para continuar no vídeo quando você aproxima a tela.
final class CameraBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lupa.camera")
    private static let diameter: CGFloat = 220

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
            x: screen.visibleFrame.maxX - size - 32,
            y: screen.visibleFrame.minY + 32,
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

        let session = session
        sessionQueue.async { session.startRunning() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        let session = session
        sessionQueue.async {
            session.stopRunning()
            session.inputs.forEach { session.removeInput($0) }
        }
    }
}
