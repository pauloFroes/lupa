import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case displayNotFound
    case writerFailed(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .displayNotFound: String(localized: "Could not find the selected display.")
        case let .writerFailed(reason): String(localized: "The file could not be written: \(reason)")
        case .nothingRecorded: String(localized: "No frames arrived from the screen; nothing was recorded.")
        }
    }
}

/// Records a display to a `.mov` with `AVAssetWriter`.
///
/// Video is written at a constant frame rate: ScreenCaptureKit sends no frames while the screen is
/// still, so the last frame is repeated to keep editors that dislike VFR happy. Microphone and
/// system audio go to separate tracks.
///
/// Thread safety is manual, hence `@unchecked Sendable`: all writer state is confined to `queue`,
/// and `stream` is only touched from the main actor in `start` and `stop`.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "io.github.paulofroes.lupa.recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var clickInput: AVAssetWriterInput?
    private var clickTrack: ClickSoundTrack?
    // Click sounds mixed into the first audio track (voice, or system audio when there is no voice).
    private var clickMixer: ClickMixer?
    private var clickMixInput: AVAssetWriterInput?
    private let clickListener = ClickListener()
    private var sessionStart = CMTime.invalid
    private var fillTimer: DispatchSourceTimer?
    private var configuration: SCStreamConfiguration?
    private var showsClicks = false

    private var frameDuration = CMTime(value: 1, timescale: 60)
    private var sessionStarted = false
    private var lastVideoTime = CMTime.invalid
    private var lastPixelBuffer: CVPixelBuffer?
    private var paused = false
    private var pauseBegan = CMTime.invalid
    private var pausedTotal = CMTime.zero
    private var failed = false
    private(set) var outputURL: URL?

    // MARK: - Lifecycle

    func start(screen: NSScreen, area: CGRect?, options: RecordingOptions, excluding windowIDs: [CGWindowID] = [])
        async throws
    {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = ScreenCapture.displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.displayNotFound
        }
        // Zoom, drawing, the camera bubble and live zoom are all part of the video; only the
        // recording control bar is left out.
        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = Self.configuration(screen: screen, area: area, options: options)
        let url = try Self.makeOutputURL(in: Self.folder(for: options))
        try setUpWriter(url: url, configuration: configuration, options: options)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if options.microphone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
        self.configuration = configuration
        showsClicks = options.showClicks
        startFillTimer()
        if clickInput != nil || clickMixer != nil {
            clickListener.start { [weak self] in self?.clickArrived() }
        }
    }

    /// During live zoom Lupa draws its own magnified cursor in the right spot; the system cursor and
    /// click rings would land on the real, unmagnified position.
    func setLiveCursor(_ live: Bool) {
        guard let stream, let configuration else { return }
        configuration.showsCursor = !live
        configuration.showMouseClicks = !live && showsClicks
        Task { try? await stream.updateConfiguration(configuration) }
    }

    func pause() {
        queue.async {
            guard !self.paused else { return }
            self.paused = true
            self.pauseBegan = Self.hostNow()
        }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            self.pausedTotal = CMTimeAdd(self.pausedTotal, CMTimeSubtract(Self.hostNow(), self.pauseBegan))
            self.paused = false
        }
    }

    func stop() async throws -> URL {
        clickListener.stop()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finish { result in continuation.resume(with: result) }
            }
        }
    }

    // MARK: - Configuration

    private static func configuration(screen: NSScreen, area: CGRect?, options: RecordingOptions)
        -> SCStreamConfiguration
    {
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        var size = screen.frame.size
        if let area {
            // `sourceRect` uses a top-left origin.
            configuration.sourceRect = CGRect(
                x: area.minX,
                y: screen.frame.height - area.maxY,
                width: area.width,
                height: area.height
            )
            size = area.size
        }
        configuration.width = evenPixels(size.width * scale)
        configuration.height = evenPixels(size.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.showMouseClicks = options.showClicks
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.captureMicrophone = options.microphone
        configuration.microphoneCaptureDeviceID = options.microphoneID
        return configuration
    }

    /// 4:2:0 HEVC and H.264 need even dimensions.
    private static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value) & ~1)
    }

    /// `~/Movies/Lupa`
    static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lupa", isDirectory: true)
    }

    /// The chosen folder. If it is gone (external drive unplugged, folder deleted), falls back to
    /// the default instead of losing the recording.
    static func folder(for options: RecordingOptions) -> URL {
        guard let path = options.folderPath, !path.isEmpty else { return defaultFolder }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return defaultFolder
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The last two path components with Finder display names, e.g. "Movies › Lupa".
    static func label(for folder: URL) -> String {
        let manager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let name = manager.displayName(atPath: folder.path)
        guard parent.path != folder.path, parent.path != "/" else { return name }
        return "\(manager.displayName(atPath: parent.path)) › \(name)"
    }

    private static func makeOutputURL(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(FileNames.timestamped("mov"))
    }

    private func setUpWriter(url: URL, configuration: SCStreamConfiguration, options: RecordingOptions) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let width = configuration.width
        let height = configuration.height
        let fps = options.framesPerSecond
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(
                width: width, height: height, fps: fps, quality: options.quality
            ))
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else {
            throw RecordingError.writerFailed(String(localized: "the video track was rejected"))
        }
        writer.add(video)

        // The microphone is the first audio track: players and editors that only play one track
        // then play the voice rather than (often silent) system audio. Its channel count is only
        // known from the first buffer, so the track is declared mono and the writer converts.
        if options.microphone {
            let mic = AVAssetWriterInput(
                mediaType: .audio, outputSettings: Self.audioSettings(channels: 1, bitRate: 128_000))
            mic.expectsMediaDataInRealTime = true
            if writer.canAdd(mic) {
                writer.add(mic)
                microphoneInput = mic
            }
        }
        if options.systemAudio {
            let audio = AVAssetWriterInput(
                mediaType: .audio, outputSettings: Self.audioSettings(channels: 2, bitRate: 256_000))
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                systemAudioInput = audio
            }
        }

        // Click sounds are mixed into the first track, the one ordinary players play. With neither
        // voice nor system audio they get a track of their own.
        if options.recordsClickSounds, let primary = microphoneInput ?? systemAudioInput {
            clickMixer = ClickMixer(defaultFormat: microphoneInput == nil ? ClickMixer.systemAudioFormat() : nil)
            clickMixInput = primary
        } else if options.recordsClickSounds {
            let clicks = AVAssetWriterInput(
                mediaType: .audio, outputSettings: Self.audioSettings(channels: 1, bitRate: 96_000))
            clicks.expectsMediaDataInRealTime = true
            if writer.canAdd(clicks) {
                writer.add(clicks)
                clickInput = clicks
                clickTrack = ClickSoundTrack()
            }
        }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? String(localized: "unknown error"))
        }
        self.writer = writer
        videoInput = video
        self.adaptor = adaptor
        outputURL = url
    }

    private static func videoSettings(width: Int, height: Int, fps: Int, quality: RecordingOptions.Quality) -> [String:
        Any]
    {
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        var settings: [String: Any] = [
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: color,
        ]
        let pixelsPerSecond = Double(width * height * fps)
        switch quality {
        case .prores:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int((pixelsPerSecond * 0.08).clamped(10e6, 120e6)),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
        case .h264:
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int((pixelsPerSecond * 0.15).clamped(16e6, 160e6)),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        }
        return settings
    }

    private static func audioSettings(channels: Int, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    // MARK: - Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !failed, !paused, sampleBuffer.isValid else { return }
        switch type {
        case .screen: appendVideo(sampleBuffer)
        case .audio: appendAudio(sampleBuffer, to: systemAudioInput)
        case .microphone: appendAudio(sampleBuffer, to: microphoneInput)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.failed = true
            DispatchQueue.main.async { self.onFailure?(error) }
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let time = CMTimeSubtract(sampleBuffer.presentationTimeStamp, pausedTotal)
        if !sessionStarted {
            writer?.startSession(atSourceTime: time)
            sessionStarted = true
            sessionStart = time
        } else if lastVideoTime.isValid, CMTimeCompare(time, lastVideoTime) <= 0 {
            return
        }
        appendPixelBuffer(pixelBuffer, at: time)
    }

    private func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let videoInput, let adaptor, videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
            lastPixelBuffer = pixelBuffer
        } else {
            reportWriterFailure()
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted, let input, input.isReadyForMoreMediaData else { return }
        guard let retimed = Self.retimed(sampleBuffer, minus: pausedTotal) else { return }
        var output = retimed
        if input === clickMixInput, let clickMixer {
            guard let mixed = clickMixer.mix(retimed, arrivedAt: CMTimeSubtract(Self.hostNow(), pausedTotal)) else {
                return
            }
            output = mixed
        }
        if !input.append(output) { reportWriterFailure() }
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer, minus offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return copy
    }

    /// A still screen produces no frames, so this timer repeats the last one to keep the rate constant.
    private func startFillTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(1e9 * frameDuration.seconds))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.fillStaticFrame()
            self?.writeClickAudio()
        }
        timer.resume()
        fillTimer = timer
    }

    private func fillStaticFrame() {
        guard !failed, !paused, sessionStarted, let lastPixelBuffer, lastVideoTime.isValid else { return }
        let now = CMTimeSubtract(Self.hostNow(), pausedTotal)
        let gap = CMTimeSubtract(now, lastVideoTime)
        guard CMTimeCompare(gap, CMTimeMultiply(frameDuration, multiplier: 2)) >= 0 else { return }
        appendPixelBuffer(lastPixelBuffer, at: CMTimeAdd(lastVideoTime, frameDuration))
    }

    // MARK: - Click sounds (on `queue`)

    private func clickArrived() {
        let now = Self.hostNow()
        queue.async {
            guard !self.failed, !self.paused, self.sessionStarted else { return }
            let time = CMTimeSubtract(now, self.pausedTotal)
            self.clickTrack?.addClick(at: time)
            self.clickMixer?.addClick(at: time)
        }
    }

    /// The click track runs slightly behind the clock so a click that just arrived still fits.
    private func writeClickAudio(upTo end: CMTime? = nil) {
        fillClickMix()
        guard !failed, !paused, sessionStarted, let track = clickTrack, let input = clickInput,
            input.isReadyForMoreMediaData
        else { return }
        let target = end ?? CMTimeSubtract(CMTimeSubtract(Self.hostNow(), pausedTotal), CMTime(value: 1, timescale: 12))
        guard let buffer = track.render(from: sessionStart, upTo: target) else { return }
        if !input.append(buffer) { reportWriterFailure() }
    }

    /// When the primary track has had no buffers for half a second (silent system audio), writes
    /// silence with the clicks up to 0.3 s ago.
    private func fillClickMix() {
        guard !failed, !paused, sessionStarted, let mixer = clickMixer, let input = clickMixInput,
            input.isReadyForMoreMediaData
        else { return }
        let now = CMTimeSubtract(Self.hostNow(), pausedTotal)
        let end = CMTimeSubtract(now, CMTime(value: 3, timescale: 10))
        guard let buffer = mixer.filler(from: sessionStart, upTo: end, now: now, quiet: CMTime(value: 1, timescale: 2))
        else { return }
        if !input.append(buffer) { reportWriterFailure() }
    }

    private func reportWriterFailure() {
        guard !failed, let writer, writer.status == .failed else { return }
        failed = true
        let error = RecordingError.writerFailed(
            writer.error?.localizedDescription ?? String(localized: "unknown error"))
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    private func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        fillTimer?.cancel()
        fillTimer = nil
        guard let writer, let url = outputURL else {
            completion(.failure(RecordingError.nothingRecorded))
            return
        }
        guard sessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            let error: Error =
                writer.error.map { RecordingError.writerFailed($0.localizedDescription) }
                ?? RecordingError.nothingRecorded
            completion(.failure(error))
            return
        }
        if paused {
            pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(Self.hostNow(), pauseBegan))
            paused = false
        }
        let end = CMTimeSubtract(Self.hostNow(), pausedTotal)
        if let lastPixelBuffer, CMTimeCompare(end, lastVideoTime) > 0 {
            appendPixelBuffer(lastPixelBuffer, at: end)
        }
        writeClickAudio(upTo: lastVideoTime)
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        clickInput?.markAsFinished()
        writer.endSession(atSourceTime: lastVideoTime)
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(
                    .failure(
                        RecordingError.writerFailed(
                            writer.error?.localizedDescription ?? String(localized: "unknown error"))))
            }
        }
        lastPixelBuffer = nil
    }

    private static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}
