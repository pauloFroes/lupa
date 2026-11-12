import AppKit
import CoreMedia

// Som de clique do mouse no vídeo, como no Screen Studio. Players comuns (WhatsApp, navegador)
// tocam só a primeira faixa de áudio, então o clique é misturado nela (ClickMixer). Sem voz nem
// som do sistema, vira a única faixa (ClickSoundTrack). O som é sintetizado aqui.

// Faixa só de cliques, contínua (silêncio entre eles) para players não estranharem buracos.
// Usado só na fila do ScreenRecorder.
final class ClickSoundTrack {
    static let sampleRate: Int32 = 48000

    private static let sound = ClickSound.samples(rate: Double(sampleRate))
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

}

enum ClickSound {
    private static var cache: [Double: [Float]] = [:]
    private static let lock = NSLock()

    static func samples(rate: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[rate] { return cached }
        let made = make(rate: rate)
        cache[rate] = made
        return made
    }

    // Um "tec" curto de mouse: estalo agudo, corpo médio e um toque grave, com chiado no ataque.
    private static func make(rate: Double) -> [Float] {
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

// Mistura os cliques na faixa principal (voz ou som do sistema), buffer a buffer. Se a faixa fica
// sem buffers (som do sistema em silêncio pode não gerar nenhum), o recheio escreve silêncio com
// os cliques no mesmo formato, e buffers que chegarem atrasados para esse trecho são descartados.
// Usado só na fila do ScreenRecorder; os tempos já estão na linha do tempo do vídeo.
final class ClickMixer {
    private var pending: [CMTime] = []
    private var format: CMAudioFormatDescription?
    private(set) var cursor = CMTime.invalid
    private var lastArrival = CMTime.invalid

    // Formato conhecido de antemão (som do sistema: 48 kHz, 2 canais, float não intercalado).
    init(defaultFormat: CMAudioFormatDescription? = nil) {
        format = defaultFormat
    }

    static func systemAudioFormat() -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        return format
    }

    func addClick(at time: CMTime) {
        if cursor.isValid, CMTimeCompare(time, cursor) < 0 {
            pending.append(cursor)
        } else {
            pending.append(time)
        }
    }

    // O buffer com os cliques misturados; nil = descartar (trecho já escrito pelo recheio).
    func mix(_ buffer: CMSampleBuffer, arrivedAt now: CMTime) -> CMSampleBuffer? {
        let start = buffer.presentationTimeStamp
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard let description = buffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return buffer }
        let rate = asbd.mSampleRate
        if cursor.isValid, CMTimeCompare(start, CMTimeSubtract(cursor, CMTime(value: 1, timescale: 1000))) < 0 {
            return nil
        }
        lastArrival = now
        cursor = CMTimeAdd(start, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
        guard Self.supports(asbd), let data = Self.planes(of: buffer, frames: frames, asbd: asbd) else {
            return buffer
        }
        format = description
        var samples = data
        let clicked = mixClicks(into: &samples, frames: frames, start: start, asbd: asbd)
        guard clicked else { return buffer }
        return Self.sampleBuffer(samples, frames: frames, at: start, format: description) ?? buffer
    }

    // Silêncio com cliques de onde a faixa parou até `end`, se nenhum buffer chegou há um tempo.
    func filler(from sessionStart: CMTime, upTo end: CMTime, now: CMTime, quiet: CMTime) -> CMSampleBuffer? {
        guard let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              Self.supports(asbd) else { return nil }
        if lastArrival.isValid, CMTimeCompare(CMTimeSubtract(now, lastArrival), quiet) < 0 { return nil }
        let start = cursor.isValid ? cursor : sessionStart
        let rate = asbd.mSampleRate
        let frames = Int((CMTimeSubtract(end, start).seconds * rate).rounded(.down))
        guard frames > 0 else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        var samples = [Float](repeating: 0, count: frames * channels)
        _ = mixClicks(into: &samples, frames: frames, start: start, asbd: asbd)
        cursor = CMTimeAdd(start, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
        return Self.sampleBuffer(samples, frames: frames, at: start, format: format)
    }

    // `samples`: canais em planos (não intercalado) ou intercalados, como no formato.
    private func mixClicks(into samples: inout [Float], frames: Int, start: CMTime, asbd: AudioStreamBasicDescription) -> Bool {
        guard !pending.isEmpty else { return false }
        let rate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let sound = ClickSound.samples(rate: rate)
        let end = CMTimeAdd(start, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
        var clicked = false
        for click in pending {
            let offset = Int((CMTimeSubtract(click, start).seconds * rate).rounded())
            let from = max(0, offset)
            let to = min(frames, offset + sound.count)
            guard from < to else { continue }
            clicked = true
            for frame in from..<to {
                let value = sound[frame - offset]
                for channel in 0..<channels {
                    let index = interleaved ? frame * channels + channel : channel * frames + frame
                    samples[index] = max(-1, min(1, samples[index] + value))
                }
            }
        }
        let length = Double(sound.count) / rate
        pending.removeAll { CMTimeCompare(CMTimeAdd($0, CMTime(seconds: length, preferredTimescale: 48000)), end) <= 0 }
        return clicked
    }

    private static func supports(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mBitsPerChannel == 32
            && asbd.mChannelsPerFrame > 0
            && asbd.mSampleRate > 0
    }

    // Copia o áudio do buffer: planos em sequência (não intercalado) ou um bloco intercalado.
    private static func planes(of buffer: CMSampleBuffer, frames: Int, asbd: AudioStreamBasicDescription) -> [Float]? {
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
        ) == noErr else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        var samples = [Float]()
        samples.reserveCapacity(frames * channels)
        for audio in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = audio.mData else { return nil }
            let count = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
            samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        return samples.count == frames * channels ? samples : nil
    }

    private static func sampleBuffer(_ samples: [Float], frames: Int, at time: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
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
            sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &buffer
        )
        return buffer
    }
}
