import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

struct RecordingOptions: Codable, Equatable {
    enum Source: String, Codable { case display, area }

    enum Quality: String, Codable, CaseIterable {
        case hevc
        case h264
        case prores

        var label: String {
            switch self {
            case .hevc: "Alta · HEVC"
            case .h264: "Compatível · H.264"
            case .prores: "Máxima · ProRes"
            }
        }
    }

    var source: Source = .display
    var systemAudio = true
    var microphone = false
    var microphoneID: String?
    var camera = false
    var showClicks = true
    var quality: Quality = .hevc
    var framesPerSecond = 60
    // Última área escolhida e último lugar da bolha da câmera, em pontos da tela (origem embaixo
    // à esquerda); voltam na próxima gravação.
    var lastArea: CGRect?
    var cameraOrigin: CGPoint?
}

enum RecordingError: LocalizedError {
    case displayNotFound
    case writerFailed(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "Não achei a tela escolhida."
        case let .writerFailed(reason): "O arquivo não pôde ser gravado: \(reason)"
        case .nothingRecorded: "Nenhum quadro chegou da tela; nada foi gravado."
        }
    }
}

// Grava a tela num .mov com AVAssetWriter: vídeo em quadros constantes (o quadro anterior se
// repete quando a tela fica parada, para editores não estranharem VFR), som do sistema e
// microfone em faixas separadas. Todo o estado do arquivo vive na fila `queue`.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "lupa.recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
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

    // MARK: - Ciclo

    func start(screen: NSScreen, area: CGRect?, options: RecordingOptions, excluding windowIDs: [CGWindowID] = []) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = ScreenCapture.displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.displayNotFound
        }
        // Zoom, desenho, bolha da câmera e zoom ao vivo entram no vídeo.
        // Só a barra de controle da gravação fica de fora.
        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = Self.configuration(screen: screen, area: area, options: options)
        let url = try Self.makeOutputURL()
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
    }

    // No Ao vivo a Lupa desenha o próprio cursor, ampliado e no lugar certo da imagem; o do sistema
    // e o círculo do clique cairiam no ponto real, fora do zoom.
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

    // MARK: - Configuração

    private static func configuration(screen: NSScreen, area: CGRect?, options: RecordingOptions) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        var size = screen.frame.size
        if let area {
            // sourceRect usa a origem no canto superior esquerdo da tela.
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

    // HEVC e H.264 em 4:2:0 exigem largura e altura pares.
    private static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value) & ~1)
    }

    // ~/Filmes/Lupa
    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lupa", isDirectory: true)
    }

    private static func makeOutputURL() throws -> URL {
        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return folder.appendingPathComponent("Lupa \(formatter.string(from: Date())).mov")
    }

    private func setUpWriter(url: URL, configuration: SCStreamConfiguration, options: RecordingOptions) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let width = configuration.width
        let height = configuration.height
        let fps = options.framesPerSecond
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(
            width: width, height: height, fps: fps, quality: options.quality
        ))
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw RecordingError.writerFailed("vídeo recusado") }
        writer.add(video)

        if options.systemAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 2, bitRate: 256_000))
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                systemAudioInput = audio
            }
        }
        // O microfone chega com o número de canais do aparelho, que só se conhece no primeiro
        // buffer; a faixa é declarada mono e o conversor do writer ajusta.
        if options.microphone {
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 1, bitRate: 128_000))
            mic.expectsMediaDataInRealTime = true
            if writer.canAdd(mic) {
                writer.add(mic)
                microphoneInput = mic
            }
        }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "erro desconhecido")
        }
        self.writer = writer
        videoInput = video
        self.adaptor = adaptor
        outputURL = url
    }

    private static func videoSettings(width: Int, height: Int, fps: Int, quality: RecordingOptions.Quality) -> [String: Any] {
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

    // MARK: - Amostras (fila `queue`)

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
        if !input.append(retimed) { reportWriterFailure() }
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer, minus offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
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

    // Tela parada não gera quadro no ScreenCaptureKit: o timer repete o último para manter a
    // taxa constante.
    private func startFillTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(1e9 * frameDuration.seconds))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.fillStaticFrame() }
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

    private func reportWriterFailure() {
        guard !failed, let writer, writer.status == .failed else { return }
        failed = true
        let error = RecordingError.writerFailed(writer.error?.localizedDescription ?? "erro desconhecido")
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
            let error: Error = writer.error.map { RecordingError.writerFailed($0.localizedDescription) }
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
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        writer.endSession(atSourceTime: lastVideoTime)
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(RecordingError.writerFailed(writer.error?.localizedDescription ?? "erro desconhecido")))
            }
        }
        lastPixelBuffer = nil
    }

    private static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}
