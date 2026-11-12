import AVFoundation
import AppKit
import SwiftUI

// Prévia redonda da câmera no painel de gravação, igual à bolha (espelhada, borda lime).
// Abre a câmera só enquanto o painel mostra a prévia.
struct CameraPreview: NSViewRepresentable {
    let deviceID: String?

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.use(deviceID: deviceID)
        return view
    }

    func updateNSView(_ view: CameraPreviewView, context: Context) {
        view.use(deviceID: deviceID)
    }

    static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) {
        view.stop()
    }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lupa.camera.preview")
    private let preview: AVCaptureVideoPreviewLayer
    private let message = NSTextField(labelWithString: "")
    private var currentID: String?
    private var wanted: String?
    private var stopped = false

    override init(frame: NSRect) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.borderColor = Theme.lime.cgColor
        layer?.borderWidth = 3
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)

        message.font = .systemFont(ofSize: 11, weight: .medium)
        message.textColor = .white
        message.alignment = .center
        message.maximumNumberOfLines = 3
        message.isHidden = true
        addSubview(message)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
        message.frame = bounds.insetBy(dx: 12, dy: bounds.height / 2 - 20)
    }

    func use(deviceID: String?) {
        wanted = deviceID
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            connect()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.use(deviceID: self.wanted)
                }
            }
        default:
            show("Sem acesso à câmera")
        }
    }

    func stop() {
        stopped = true
        let session = session
        queue.async {
            session.stopRunning()
            session.inputs.forEach { session.removeInput($0) }
        }
    }

    private func connect() {
        guard !stopped else { return }
        guard let device = CameraBubble.pickCamera(id: wanted) else {
            show("Nenhuma câmera")
            return
        }
        guard device.uniqueID != currentID else { return }
        currentID = device.uniqueID
        message.isHidden = true
        let session = session
        queue.async { [weak self] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.sessionPreset = .high
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self?.mirror() }
        }
    }

    private func mirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    private func show(_ text: String) {
        message.stringValue = text
        message.isHidden = false
    }
}
