import AVFoundation
import AppKit

// Legenda e transcrição ao vivo: microfone → OpenAI (gpt-live-transcribe) → faixa na tela.
// O texto aparece enquanto se fala; a cada pausa o trecho fecha e vira texto final. Ao parar,
// a transcrição vai para Filmes › Lupa › Transcrições; gravando, sai também um .srt ao lado do vídeo.
final class CaptionController {
    private(set) var isActive = false
    var onChange: (() -> Void)?
    // Tempo corrido da gravação, quando há uma rodando: marca os trechos do .srt.
    var recordingClock: () -> TimeInterval? = { nil }

    private let prefs = Preferences.shared
    private let model = CaptionModel()
    private lazy var window = CaptionWindow(model: model)
    private var microphone: MicrophoneStream?
    private var transcriber: RealtimeTranscriber?
    private var ready = false
    private var buffered: [Data] = []

    // VAD simples no cliente: fala é o nível bem acima do ruído de fundo (que a Lupa vai medindo);
    // uma pausa de `silenceToCommit` fecha o trecho. Um trecho nunca passa de `maxTurn`.
    private static let minSpeechLevel: Float = 0.012
    private static let silenceToCommit: TimeInterval = 0.6
    private static let maxTurn: TimeInterval = 12
    private var noiseFloor: Float = 0.004
    private var stats = (chunks: 0, commits: 0, deltas: 0, finals: 0)
    private var statsTimer: Timer?
    private var speaking = false
    private var turnStart: Date?
    private var lastSpeech = Date.distantPast

    private struct Segment {
        var text: String
        var final: Bool
        var start: Date
        var end: Date
        var recordingStart: TimeInterval?
        var recordingEnd: TimeInterval?
    }

    private var order: [String] = []
    private var segments: [String: Segment] = [:]
    private var sessionStart = Date()
    private var hideTimer: Timer?
    private var retries = 0
    private var area: CGRect?
    private var screen: NSScreen?

    // MARK: - Ligar e desligar

    func toggle(on screen: NSScreen, area: CGRect? = nil) {
        if isActive { stop() } else { start(on: screen, area: area) }
    }

    func start(on screen: NSScreen, area: CGRect? = nil) {
        guard !isActive else {
            move(to: screen, area: area)
            return
        }
        NSLog("Lupa legenda: ligando")
        guard let key = OpenAIKey.value else {
            flash("legenda: cadastre a chave da OpenAI em Ajustes", on: screen, area: area)
            return
        }
        Task { @MainActor in
            guard await Self.microphoneAccess() else {
                self.flash("legenda: permita o microfone para a Lupa em Ajustes do Sistema", on: screen, area: area)
                return
            }
            self.begin(key: key, screen: screen, area: area)
        }
    }

    func stop() {
        guard isActive else { return }
        NSLog("Lupa legenda: desligando (%ld blocos de áudio, %ld trechos fechados, %ld pedaços de texto, %ld finais)",
              stats.chunks, stats.commits, stats.deltas, stats.finals)
        isActive = false
        statsTimer?.invalidate()
        statsTimer = nil
        microphone?.stop()
        microphone = nil
        if speaking { transcriber?.commit() }
        let transcriber = transcriber
        self.transcriber = nil
        // Um respiro para o último trecho chegar antes de fechar a conexão e salvar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            transcriber?.close()
            self?.saveTranscript()
        }
        hideTimer?.invalidate()
        model.visible = false
        model.notice = nil
        window.orderOut(nil)
        onChange?()
    }

    func move(to screen: NSScreen, area: CGRect?) {
        self.screen = screen
        self.area = area
        guard isActive else { return }
        let rect = area.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) } ?? screen.frame
        window.place(in: rect, fontSize: prefs.captions.size.points)
    }

    private func begin(key: String, screen: NSScreen, area: CGRect?) {
        guard !isActive else { return }
        isActive = true
        sessionStart = Date()
        order.removeAll()
        segments.removeAll()
        retries = 0
        stats = (0, 0, 0, 0)
        noiseFloor = 0.004
        speaking = false
        turnStart = nil
        model.notice = nil
        model.fontSize = prefs.captions.size.points
        model.text = ""
        model.pending = ""
        move(to: screen, area: area)
        window.orderFrontRegardless()
        connect(key: key)

        let microphone = MicrophoneStream()
        microphone.onAudio = { [weak self, weak microphone] pcm in
            let level = microphone?.level ?? 0
            DispatchQueue.main.async { self?.handleAudio(pcm, level: level) }
        }
        do {
            try microphone.start(deviceUID: prefs.recording.microphoneID)
            self.microphone = microphone
        } catch {
            fail(error)
            return
        }
        // A cada 5 s, uma linha no log com o que está passando: áudio, trechos e texto.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            NSLog("Lupa legenda: %ld blocos, %ld trechos, %ld pedaços, %ld finais, ruído %.4f, conectada %@",
                  stats.chunks, stats.commits, stats.deltas, stats.finals, noiseFloor, ready ? "sim" : "não")
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
        onChange?()
    }

    private func connect(key: String) {
        ready = false
        buffered.removeAll()
        let transcriber = RealtimeTranscriber()
        transcriber.onOpen = { [weak self] in
            guard let self, !self.ready else { return }
            self.ready = true
            self.retries = 0
            self.buffered.forEach { transcriber.append($0) }
            self.buffered.removeAll()
            if self.model.notice != nil {
                self.model.notice = nil
                self.refresh()
            }
        }
        transcriber.onText = { [weak self] item, text, final in self?.receive(item: item, text: text, final: final) }
        transcriber.onError = { [weak self] error in self?.connectionLost(error) }
        let options = prefs.captions
        let keywords = options.vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
        transcriber.connect(key: key, language: options.language, keywords: keywords)
        self.transcriber = transcriber
    }

    // Queda de rede: tenta de novo algumas vezes antes de desistir.
    private func connectionLost(_ error: Error) {
        guard isActive else { return }
        let keyProblem = (error as? TranscriberError).map {
            if case .server = $0 { return true } else { return false }
        } ?? false
        transcriber?.close()
        transcriber = nil
        ready = false
        if !keyProblem, retries < 3, let key = OpenAIKey.value {
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(retries)) { [weak self] in
                guard let self, self.isActive, self.transcriber == nil else { return }
                self.connect(key: key)
            }
            return
        }
        fail(error)
    }

    // Sem alerta modal: no Ao vivo ele ficaria escondido atrás da tela ampliada e travaria a Lupa.
    // O motivo aparece por alguns segundos no lugar da legenda.
    private func fail(_ error: Error) {
        NSLog("Lupa legenda: parou: %@", error.localizedDescription)
        let screen = screen
        let area = area
        stop()
        if let screen { flash("legenda parou: \(error.localizedDescription)", on: screen, area: area) }
    }

    private func flash(_ text: String, on screen: NSScreen, area: CGRect?) {
        NSLog("Lupa legenda: aviso: %@", text)
        let rect = area.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) } ?? screen.frame
        model.fontSize = prefs.captions.size.points
        window.place(in: rect, fontSize: model.fontSize)
        model.notice = text
        model.visible = true
        window.orderFrontRegardless()
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            guard let self else { return }
            model.visible = false
            model.notice = nil
            if !isActive { window.orderOut(nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    // MARK: - Áudio

    private func handleAudio(_ pcm: Data, level: Float) {
        guard isActive else { return }
        if ready, let transcriber {
            transcriber.append(pcm)
            stats.chunks += 1
        } else {
            // Até a sessão abrir, guarda até ~5 s para não perder o começo da fala.
            buffered.append(pcm)
            if buffered.count > 50 { buffered.removeFirst() }
        }
        let now = Date()
        // O ruído de fundo desce rápido e sobe devagar: acompanha a sala sem engolir a fala.
        noiseFloor = level < noiseFloor ? noiseFloor * 0.9 + level * 0.1 : noiseFloor * 0.998 + level * 0.002
        if level >= max(Self.minSpeechLevel, noiseFloor * 3) {
            lastSpeech = now
            if !speaking {
                speaking = true
                turnStart = now
            }
        }
        guard speaking, ready else { return }
        let silence = now.timeIntervalSince(lastSpeech)
        let long = turnStart.map { now.timeIntervalSince($0) > Self.maxTurn } ?? false
        if silence >= Self.silenceToCommit || long {
            transcriber?.commit()
            stats.commits += 1
            speaking = false
            turnStart = nil
        }
    }

    // MARK: - Texto

    private func receive(item: String, text: String, final: Bool) {
        if final { stats.finals += 1 } else { stats.deltas += 1 }
        // Texto parcial sem item_id (antes do commit) fica num balde só; o final do trecho o substitui.
        if final, !item.isEmpty, segments[""]?.final == false {
            segments[""] = nil
            order.removeAll { $0 == "" }
        }
        let now = Date()
        var segment = segments[item] ?? Segment(
            text: "", final: false, start: now, end: now,
            recordingStart: recordingClock(), recordingEnd: nil
        )
        if segments[item] == nil { order.append(item) }
        if final {
            segment.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            segment.final = true
        } else {
            segment.text += text
        }
        segment.end = now
        segment.recordingEnd = recordingClock() ?? segment.recordingStart
        segments[item] = segment
        refresh()
    }

    private func refresh() {
        guard isActive, model.notice == nil else { return }
        // As últimas falas, cortadas pelo começo para caber em duas linhas; o que ainda está sendo
        // dito fica separado, para aparecer em tom mais apagado até a OpenAI fechar o trecho.
        let recent = order.suffix(3).compactMap { segments[$0] }.filter { !$0.text.isEmpty }
        let finished = recent.filter(\.final).map(\.text).joined(separator: " ")
        let pending = recent.filter { !$0.final }.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let joined = [finished, pending].filter { !$0.isEmpty }.joined(separator: " ")
        let usable = window.frame.width - 48 - model.fontSize * 1.6
        let limit = max(40, Int(2 * usable / (model.fontSize * 0.54)))
        let shown = Self.tail(joined, limit: limit)
        let pendingShown = String(pending.suffix(min(pending.count, shown.count)))
        model.pending = pendingShown
        model.text = String(shown.dropLast(pendingShown.count)).trimmingCharacters(in: .whitespaces)
        model.visible = !shown.isEmpty
        hideTimer?.invalidate()
        // Em silêncio, a legenda some depois de alguns segundos.
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            self?.model.visible = false
            self?.model.text = ""
            self?.model.pending = ""
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    static func tail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.suffix(limit))
        guard let space = cut.firstIndex(of: " ") else { return cut }
        return String(cut[cut.index(after: space)...])
    }

    // MARK: - Arquivos

    static var transcriptFolder: URL {
        ScreenRecorder.folder.appendingPathComponent("Transcrições", isDirectory: true)
    }

    private func saveTranscript() {
        guard prefs.captions.saveTranscript else { return }
        let lines = order.compactMap { segments[$0] }.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let body = lines.map { "[\(time.string(from: $0.start))] \($0.text)" }.joined(separator: "\n")
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let folder = Self.transcriptFolder
        let url = folder.appendingPathComponent("Transcrição \(name.string(from: sessionStart)).txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
            NSLog("Lupa legenda: transcrição salva em %@", url.path)
        } catch {
            NSLog("Lupa legenda: não salvou a transcrição: %@", error.localizedDescription)
        }
    }

    // .srt com o mesmo nome do vídeo, com os trechos ditos durante aquela gravação.
    func writeSubtitles(for video: URL, recordingDuration: TimeInterval) {
        guard prefs.captions.saveTranscript else { return }
        let cues = order.compactMap { segments[$0] }
            .filter { !$0.text.isEmpty && $0.recordingStart != nil }
            .filter { ($0.recordingStart ?? 0) <= recordingDuration + 1 }
        guard !cues.isEmpty else { return }
        var srt = ""
        for (index, cue) in cues.enumerated() {
            let start = cue.recordingStart ?? 0
            var end = max(cue.recordingEnd ?? start, start + 1.2)
            end = min(end, recordingDuration)
            srt += "\(index + 1)\n\(Self.srtTime(start)) --> \(Self.srtTime(max(end, start + 0.5)))\n\(cue.text)\n\n"
        }
        let url = video.deletingPathExtension().appendingPathExtension("srt")
        try? srt.write(to: url, atomically: true, encoding: .utf8)
    }

    // A gravação nova começa do zero: os trechos de antes não têm tempo de gravação.
    func recordingStarted() {
        for item in order {
            segments[item]?.recordingStart = nil
            segments[item]?.recordingEnd = nil
        }
    }

    private static func srtTime(_ seconds: TimeInterval) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }

    // MARK: - Permissões e chave

    private static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    var onOpenSettings: (() -> Void)?
}
