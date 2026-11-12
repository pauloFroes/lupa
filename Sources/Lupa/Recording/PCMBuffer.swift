import AVFoundation

/// Builders for 32-bit float linear PCM sample buffers.
enum PCMBuffer {
    static func floatFormat(sampleRate: Double, channels: Int, interleaved: Bool) -> CMAudioFormatDescription? {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        // For non-interleaved audio the byte counts describe a single channel.
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (interleaved ? channels : 1))
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
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

    /// Copies `samples` (laid out as `format` describes) into a new sample buffer of `frames` frames.
    static func make(
        _ samples: [Float],
        frames: Int,
        at time: CMTime,
        format: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let length = samples.count * MemoryLayout<Float>.size
        guard length > 0 else { return nil }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            ) == kCMBlockBufferNoErr, let block
        else { return nil }
        let copied = samples.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length
            )
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
