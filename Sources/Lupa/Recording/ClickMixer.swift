import AVFoundation

/// Mixes click sounds into the primary audio track (voice or system audio), buffer by buffer.
///
/// Silent system audio may produce no buffers at all; `filler` then writes silence with the clicks
/// in the same format, and buffers that arrive late for that stretch are dropped.
///
/// Not thread-safe: only touched from `ScreenRecorder`'s queue. All times are on the video timeline.
final class ClickMixer {
    private var pending: [CMTime] = []
    private var format: CMAudioFormatDescription?
    private(set) var cursor = CMTime.invalid
    private var lastArrival = CMTime.invalid

    /// `defaultFormat` is known up front for system audio (48 kHz, stereo, non-interleaved float).
    init(defaultFormat: CMAudioFormatDescription? = nil) {
        format = defaultFormat
    }

    static func systemAudioFormat() -> CMAudioFormatDescription? {
        PCMBuffer.floatFormat(sampleRate: 48000, channels: 2, interleaved: false)
    }

    func addClick(at time: CMTime) {
        if cursor.isValid, CMTimeCompare(time, cursor) < 0 {
            pending.append(cursor)
        } else {
            pending.append(time)
        }
    }

    /// The buffer with clicks mixed in, or `nil` to drop it (that stretch was already filled).
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
        return PCMBuffer.make(samples, frames: frames, at: start, format: description) ?? buffer
    }

    /// Silence plus clicks from where the track left off up to `end`, if no buffer arrived for `quiet`.
    func filler(from sessionStart: CMTime, upTo end: CMTime, now: CMTime, quiet: CMTime) -> CMSampleBuffer? {
        guard let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            Self.supports(asbd)
        else { return nil }
        if lastArrival.isValid, CMTimeCompare(CMTimeSubtract(now, lastArrival), quiet) < 0 { return nil }
        let start = cursor.isValid ? cursor : sessionStart
        let rate = asbd.mSampleRate
        let frames = Int((CMTimeSubtract(end, start).seconds * rate).rounded(.down))
        guard frames > 0 else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        var samples = [Float](repeating: 0, count: frames * channels)
        _ = mixClicks(into: &samples, frames: frames, start: start, asbd: asbd)
        cursor = CMTimeAdd(start, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
        return PCMBuffer.make(samples, frames: frames, at: start, format: format)
    }

    /// `samples` holds planar or interleaved channels, as the format says.
    private func mixClicks(into samples: inout [Float], frames: Int, start: CMTime, asbd: AudioStreamBasicDescription)
        -> Bool
    {
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

    /// Copies the buffer's audio: planes back to back (non-interleaved) or one interleaved block.
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
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
            ) == noErr
        else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        var samples = [Float]()
        samples.reserveCapacity(frames * channels)
        for audio in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = audio.mData else { return nil }
            let count = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
            samples.append(
                contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        return samples.count == frames * channels ? samples : nil
    }
}
