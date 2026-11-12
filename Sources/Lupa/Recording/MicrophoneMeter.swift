import AVFoundation
import SwiftUI

// Nível do microfone no painel de gravação: antes de gravar, dá para ver que a voz está chegando
// no microfone escolhido. Abre o microfone só enquanto o painel mostra o medidor.
final class MicrophoneLevel: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    // 0…1, já suavizado para a barra não tremer.
    @Published private(set) var level: Double = 0
    @Published private(set) var problem: String?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "lupa.microphone.meter")
    private var currentID: String?
    private var wanted: String?
    private var stopped = false
    private var smoothed = 0.0

    func use(deviceID: String?) {
        wanted = deviceID
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            connect()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.use(deviceID: self.wanted)
                }
            }
        default:
            problem = "Sem acesso ao microfone"
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

    // O mesmo aparelho que a gravação usa: o escolhido ou, sem escolha, o padrão do sistema.
    private func device() -> AVCaptureDevice? {
        if let wanted, let chosen = AVCaptureDevice(uniqueID: wanted), chosen.isConnected { return chosen }
        return AVCaptureDevice.default(for: .audio)
    }

    private func connect() {
        guard !stopped else { return }
        guard let device = device() else {
            problem = "Nenhum microfone"
            return
        }
        problem = nil
        guard device.uniqueID != currentID else { return }
        currentID = device.uniqueID
        let session = session
        let output = output
        queue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.outputs.isEmpty, session.canAddOutput(output) {
                output.setSampleBufferDelegate(self, queue: self.queue)
                session.addOutput(output)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let channels = connection.audioChannels
        guard !channels.isEmpty else { return }
        // averagePowerLevel em dB (0 = máximo). −50 dB vira barra vazia.
        let power = Double(channels.map(\.averagePowerLevel).max() ?? -160)
        let target = ((power + 50) / 50).clamped(0, 1)
        // Sobe rápido e desce devagar, como um VU.
        smoothed = target > smoothed ? target : smoothed * 0.85 + target * 0.15
        let value = smoothed
        DispatchQueue.main.async { [weak self] in self?.level = value }
    }
}

struct MicrophoneMeter: View {
    let deviceID: String?
    @StateObject private var model = MicrophoneLevel()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(model.level > 0.15 ? Palette.lime : Palette.onInkMuted)
            if let problem = model.problem {
                Text(problem)
                    .font(.lupaText(12))
                    .foregroundColor(Palette.danger)
                Spacer()
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.inkBorder)
                        Capsule()
                            .fill(model.level > 0.92 ? Palette.danger : Palette.lime)
                            .frame(width: max(4, geo.size.width * model.level))
                            .animation(.linear(duration: 0.08), value: model.level)
                    }
                }
                .frame(height: 6)
            }
        }
        .frame(height: 16)
        .help("Fale: a barra deve se mexer. Parada, o microfone não está pegando sua voz.")
        .onAppear { model.use(deviceID: deviceID) }
        .onChange(of: deviceID) { _, id in model.use(deviceID: id) }
        .onDisappear { model.stop() }
    }
}
