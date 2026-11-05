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

    // VAD simples no cliente: fala acima do limiar; uma pausa de `silenceToCommit` fecha o trecho.
    private static let speechLevel: Float = 0.035
    private static let silenceToCommit: TimeInterval = 0.7
    private static let maxTurn: TimeInterval = 14
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
        guard let key = OpenAIKey.value else {
            askForKey()
            return
        }
        Task { @MainActor in
            guard await Self.microphoneAccess() else {
                self.showMicrophoneAlert()
                return
            }
            self.begin(key: key, screen: screen, area: area)
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
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
        model.fontSize = prefs.captions.size.points
        model.text = ""
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
        }
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

    private func fail(_ error: Error) {
        NSLog("Lupa legenda: parou: %@", error.localizedDescription)
        stop()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "a legenda parou"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Áudio

    private func handleAudio(_ pcm: Data, level: Float) {
        guard isActive else { return }
        if ready, let transcriber {
            transcriber.append(pcm)
        } else {
            // Até a sessão abrir, guarda até ~5 s para não perder o começo da fala.
            buffered.append(pcm)
            if buffered.count > 50 { buffered.removeFirst() }
        }
        let now = Date()
        if level >= Self.speechLevel {
            lastSpeech = now
            if !speaking {
                speaking = true
                turnStart = now
            }
        }
        guard speaking, ready else { return }
        let silence = now.timeIntervalSince(lastSpeech)
        let long = turnStart.map { now.timeIntervalSince($0) > Self.maxTurn } ?? false
        if silence >= Self.silenceToCommit || (long && silence > 0.15) {
            transcriber?.commit()
            speaking = false
            turnStart = nil
        }
    }

    // MARK: - Texto

    private func receive(item: String, text: String, final: Bool) {
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
        // As últimas falas, cortadas pelo começo para caber em duas linhas.
        let recent = order.suffix(3).compactMap { segments[$0]?.text }.filter { !$0.isEmpty }
        let joined = recent.joined(separator: " ")
        let limit = Int(2 * (window.frame.width - 44) / (model.fontSize * 0.52))
        model.text = Self.tail(joined, limit: max(40, limit))
        model.visible = !model.text.isEmpty
        hideTimer?.invalidate()
        // Em silêncio, a legenda some depois de alguns segundos.
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            self?.model.visible = false
            self?.model.text = ""
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

    private func showNotice(_ text: String) {
        hideTimer?.invalidate()
        model.notice = text
        model.visible = true
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

    private func askForKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cadastre a chave da OpenAI"
        alert.informativeText = "A legenda ao vivo usa a transcrição em tempo real da OpenAI. Cole a sua chave em Ajustes › Legenda e transcrição; ela fica guardada no chaveiro do Mac."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")
        if alert.runModal() == .alertFirstButtonReturn { onOpenSettings?() }
    }

    private func showMicrophoneAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A Lupa não tem acesso ao microfone"
        alert.informativeText = "A legenda precisa ouvir a sua voz. Ligue a Lupa em Ajustes do Sistema › Privacidade e Segurança › Microfone."
        alert.addButton(withTitle: "Abrir Ajustes do Sistema")
        alert.addButton(withTitle: "Agora não")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
