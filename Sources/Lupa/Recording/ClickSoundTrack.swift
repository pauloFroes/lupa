import AVFoundation

/// A dedicated click-sound track, used when the recording has no other audio. It is continuous,
/// with silence between clicks, because some players misbehave on gaps.
///
/// Not thread-safe: only touched from `ScreenRecorder`'s queue.
final class ClickSoundTrack {
    static let sampleRate: Int32 = 48000

    private static let sound = ClickSound.samples(rate: Double(sampleRate))
    private var cursor: Int64?
    private var pending: [Int64] = []
    private var format: CMAudioFormatDescription?

    init() {
        format = PCMBuffer.floatFormat(sampleRate: Double(Self.sampleRate), channels: 1, interleaved: true)
    }

    /// `time` is on the video timeline (pauses removed). A click that arrives late plays at the
    /// first instant not yet written.
    func addClick(at time: CMTime) {
        var index = Self.sampleIndex(time)
        if let cursor { index = max(index, cursor) }
        pending.append(index)
    }

    /// Audio from where the track left off (or `start`) up to `end`, with clicks mixed in.
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
        return PCMBuffer.make(
            samples, frames: samples.count, at: CMTime(value: begin, timescale: Self.sampleRate), format: format)
    }

    private static func sampleIndex(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: sampleRate, method: .roundHalfAwayFromZero).value
    }
}
