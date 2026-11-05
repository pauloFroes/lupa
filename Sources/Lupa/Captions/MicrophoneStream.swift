import AVFoundation
import CoreAudio

enum MicrophoneError: LocalizedError {
    case noInput
    case converter

    var errorDescription: String? {
        switch self {
        case .noInput: "Nenhum microfone disponível."
        case .converter: "Não deu para converter o áudio do microfone."
        }
    }
}

// Lê o microfone e entrega PCM de 16 bits, mono, 24 kHz (o formato da transcrição da OpenAI),
// em blocos de ~100 ms. Corre à parte da gravação: o arquivo continua com a faixa do microfone
// que o ScreenCaptureKit captura.
final class MicrophoneStream {
    static let sampleRate = 24_000.0
    var onAudio: ((Data) -> Void)?
    // Nível RMS de 0 a 1 do último bloco, para saber se há fala chegando.
    private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private var pending = Data()
    private let chunkBytes = Int(sampleRate / 10) * 2

    func start(deviceUID: String?) throws {
        let input = engine.inputNode
        if let deviceUID, let device = Self.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw MicrophoneError.noInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw MicrophoneError.converter }
        self.converter = converter
        pending.removeAll()
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        if !pending.isEmpty { onAudio?(pending) }
        pending.removeAll()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        // RMS: o pico pega estalos e ruído; a média de energia separa melhor fala de silêncio.
        var sum: Float = 0
        for index in 0 ..< count {
            let sample = Float(samples[index]) / Float(Int16.max)
            sum += sample * sample
        }
        level = (sum / Float(count)).squareRoot()
        pending.append(Data(bytes: samples, count: count * 2))
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            onAudio?(Data(chunk))
        }
    }

    // O uniqueID do AVCaptureDevice de áudio é o UID do Core Audio.
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
