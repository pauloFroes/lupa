import AppKit
import CoreMedia

// Som de clique do mouse gravado numa faixa de áudio própria ("Cliques"), como no Screen Studio.
// A faixa é contínua (silêncio entre os cliques) para editores e players não estranharem buracos;
// o som é sintetizado aqui, sem arquivo de áudio. Usado só na fila do ScreenRecorder.
final class ClickSoundTrack {
    static let sampleRate: Int32 = 48000

    private static let sound = makeClick()
    private var cursor: Int64?
    private var pending: [Int64] = []
    private var format: CMAudioFormatDescription?

    init() {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
    }

    // `time` já na linha do tempo do vídeo (sem as pausas). Clique que chega atrasado toca no
    // primeiro instante ainda não escrito.
    func addClick(at time: CMTime) {
        var index = Self.sampleIndex(time)
        if let cursor { index = max(index, cursor) }
        pending.append(index)
    }

    // Áudio de onde a faixa parou (ou de `start`) até `end`, com os cliques misturados.
    func render(from start: CMTime, upTo end: CMTime) -> CMSampleBuffer? {
        let begin = cursor ?? Self.sampleIndex(start)
        let finish = Self.sampleIndex(end)
        guard finish > begin, let format else { return nil }
        let count = Int(min(finish - begin, Int64(Self.sampleRate) * 10))
        var samples = [Float](repeating: 0, count: count)
        let sound = Self.sound
        for click in pending {
            let from = max(click, begin)
            let to = min(click + Int64(sound.count), begin + Int64(count))
            guard from < to else { continue }
            for index in from..<to {
                samples[Int(index - begin)] += sound[Int(index - click)]
            }
        }
        let next = begin + Int64(count)
        pending.removeAll { $0 + Int64(sound.count) <= next }
        cursor = next
        return Self.sampleBuffer(samples, at: CMTime(value: begin, timescale: Self.sampleRate), format: format)
    }

    private static func sampleIndex(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: sampleRate, method: .roundHalfAwayFromZero).value
    }

    private static func sampleBuffer(_ samples: [Float], at time: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &buffer
        )
        return buffer
    }

    // Um "tec" curto de mouse: estalo agudo, corpo médio e um toque grave, com chiado no ataque.
    private static func makeClick() -> [Float] {
        let rate = Double(sampleRate)
        let count = Int(rate * 0.05)
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { index in
            let t = Double(index) / rate
            let attack = min(1, t / 0.0004)
            let snap = sin(2 * .pi * 3400 * t) * exp(-t / 0.0025)
            let body = sin(2 * .pi * 1250 * t) * exp(-t / 0.006)
            let thump = sin(2 * .pi * 190 * t) * exp(-t / 0.012)
            let noise = Double.random(in: -1...1, using: &generator) * exp(-t / 0.0012)
            return Float(attack * (0.32 * snap + 0.26 * body + 0.18 * thump + 0.22 * noise))
        }
    }
}

// Escuta (sem consumir) os botões do mouse em toda a sessão. Com Acessibilidade usa um event tap
// só de escuta; sem ela, o monitor global do NSEvent.
final class ClickListener {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitor: Any?
    private var onClick: (() -> Void)?

    func start(onClick: @escaping () -> Void) {
        stop()
        self.onClick = onClick
        if AXIsProcessTrusted(), startTap() { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.onClick?()
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        tap = nil
        source = nil
        monitor = nil
        onClick = nil
    }

    private func startTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<ClickListener>.fromOpaque(refcon).takeUnretainedValue().handle(type)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func handle(_ type: CGEventType) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onClick?()
        default:
            break
        }
    }
}
