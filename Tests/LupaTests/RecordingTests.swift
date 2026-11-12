import CoreMedia
import Foundation
import Testing

@testable import Lupa

struct RecordingTests {
    @Test(arguments: [(0.0, "00:00"), (59.9, "00:59"), (61, "01:01"), (3600, "1:00:00"), (3725, "1:02:05")])
    func formatsElapsedTime(seconds: TimeInterval, text: String) {
        #expect(RecordingController.format(seconds) == text)
    }

    @Test func decodesOptionsSavedBeforeClickSoundsExisted() throws {
        let legacy =
            Data(#"{"source":"display","systemAudio":true,"microphone":false,"camera":false,"#.utf8)
            + Data(#""showClicks":true,"quality":"hevc","framesPerSecond":60}"#.utf8)
        let options = try JSONDecoder().decode(RecordingOptions.self, from: legacy)
        #expect(options.recordsClickSounds == false)
        #expect(options.folderPath == nil)
    }

    @Test func clickTrackIsContinuousAndContainsTheClick() throws {
        let track = ClickSoundTrack()
        let rate = ClickSoundTrack.sampleRate
        let start = CMTime(value: 0, timescale: rate)
        track.addClick(at: CMTime(value: 4800, timescale: rate))  // 0.1 s

        let first = try #require(track.render(from: start, upTo: CMTime(value: 9600, timescale: rate)))
        #expect(CMSampleBufferGetNumSamples(first) == 9600)
        let second = try #require(track.render(from: start, upTo: CMTime(value: 14400, timescale: rate)))
        #expect(second.presentationTimeStamp == CMTime(value: 9600, timescale: rate))

        let samples = try Self.floats(first)
        #expect(samples[..<4800].allSatisfy { $0 == 0 })
        #expect(samples[4800...].contains { $0 != 0 })
    }

    @Test func clickSoundIsShortAndBounded() {
        let sound = ClickSound.samples(rate: 48000)
        #expect(sound.count == 2400)
        #expect(sound.allSatisfy { abs($0) <= 1 })
    }

    private static func floats(_ buffer: CMSampleBuffer) throws -> [Float] {
        let block = try #require(buffer.dataBuffer)
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        )
        let base = try #require(pointer)
        return base.withMemoryRebound(to: Float.self, capacity: length / 4) {
            Array(UnsafeBufferPointer(start: $0, count: length / 4))
        }
    }
}
