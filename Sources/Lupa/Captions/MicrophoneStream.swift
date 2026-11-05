import AVFoundation

enum MicrophoneError: LocalizedError {
    case noInput
    case cannotRead

    var errorDescription: String? {
        switch self {
        case .noInput: "Nenhum microfone disponível."
        case .cannotRead: "Não deu para ler o microfone."
        }
    }
}

// Lê o microfone e entrega PCM de 16 bits, mono, 24 kHz (o formato da transcrição da OpenAI),
// em blocos de ~100 ms. Usa o AVCaptureSession, que escolhe o aparelho pelo mesmo ID do painel de
// gravação e já converte o formato: o tap do AVAudioEngine lança exceção do Objective-C (que o
// Swift não pega) quando o formato do aparelho muda, como num fone Bluetooth a 16 kHz.
final class MicrophoneStream: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate = 24_000.0
    var onAudio: ((Data) -> Void)?
    // Nível RMS de 0 a 1 do último bloco, para saber se há fala chegando.
    private(set) var level: Float = 0

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lupa.captions.mic")
    private var pending = Data()
    private let chunkBytes = Int(sampleRate / 10) * 2

    func start(deviceUID: String?) throws {
        let device = deviceUID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw MicrophoneError.noInput }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneError.cannotRead
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        pending.removeAll()
        session.startRunning()
        NSLog("Lupa legenda: microfone %@", device.localizedName)
    }

    func stop() {
        session.stopRunning()
        queue.sync {
            if !pending.isEmpty { onAudio?(pending) }
            pending.removeAll()
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 1 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        // RMS: o pico pega estalos e ruído; a média de energia separa melhor fala de silêncio.
        let sum = data.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            var total: Float = 0
            for sample in samples {
                let value = Float(sample) / Float(Int16.max)
                total += value * value
            }
            return samples.isEmpty ? 0 : total / Float(samples.count)
        }
        level = sum.squareRoot()
        pending.append(data)
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            onAudio?(Data(chunk))
        }
    }
}
