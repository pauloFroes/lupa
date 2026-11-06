import Foundation

enum TranscriberError: LocalizedError {
    case missingKey
    case server(String)
    case closed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Cadastre a chave da OpenAI em Ajustes."
        case let .server(message): message
        case let .closed(reason): reason
        }
    }
}

// Transcrição em tempo real pela API Realtime da OpenAI (sessão só de transcrição, WebSocket).
// O gpt-live-transcribe devolve o texto enquanto a pessoa fala; a cada pausa a Lupa fecha o turno
// (commit) e recebe o texto final daquele trecho. Sem VAD do servidor: esse modelo não aceita.
final class RealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {

    // item_id, texto acumulado até agora, e se o trecho já é final.
    var onText: ((String, String, Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onError: ((Error) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var opened = false
    private var seenTypes = Set<String>()

    func connect(key: String, language: String, keywords: [String], choice: TranscriptionChoice) {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        closed = false
        opened = false
        seenTypes.removeAll()
        task.resume()
        var transcription: [String: Any] = ["model": choice.model]
        let cleaned = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0 != "<" && $0 != ">" } }
            .filter { !$0.isEmpty }
        if let delay = choice.delay {
            // gpt-live-transcribe: `languages` (lista) e `keywords`; não aceita `language`.
            transcription["delay"] = delay
            if !language.isEmpty { transcription["languages"] = [language] }
            if !cleaned.isEmpty { transcription["keywords"] = Array(cleaned.prefix(100)) }
        } else {
            if !language.isEmpty { transcription["language"] = language }
            if !cleaned.isEmpty { transcription["prompt"] = "Termos da aula: " + cleaned.joined(separator: ", ") }
        }
        NSLog("Lupa legenda: transcrição com %@ (%@)", choice.model, choice.delay ?? "frase inteira")
        send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(MicrophoneStream.sampleRate)],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ])
        receive()
    }

    func append(_ pcm: Data) {
        send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    func commit() {
        send(["type": "input_audio_buffer.commit"])
    }

    func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func send(_ event: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error, let self, !self.closed else { return }
            DispatchQueue.main.async { self.fail(error) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                switch result {
                case let .success(.string(text)):
                    self.handle(text)
                    self.receive()
                case let .success(.data(data)):
                    self.handle(String(decoding: data, as: UTF8.self))
                    self.receive()
                case let .failure(error):
                    self.fail(error)
                @unknown default:
                    self.receive()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        let item = event["item_id"] as? String ?? ""
        // Cada tipo de evento aparece uma vez no log (Console, processo Lupa): mostra o que a
        // OpenAI está mandando sem inundar o log com cada pedaço de texto.
        if seenTypes.insert(type).inserted { NSLog("Lupa legenda: primeiro evento %@", type) }
        switch type {
        case "session.created", "session.updated", "transcription_session.created", "transcription_session.updated":
            markOpen()
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String { onText?(item, delta, false) }
        case "conversation.item.input_audio_transcription.completed":
            onText?(item, event["transcript"] as? String ?? "", true)
        case "conversation.item.input_audio_transcription.failed":
            let message = (event["error"] as? [String: Any])?["message"] as? String
            NSLog("Lupa legenda: trecho %@ falhou: %@", item, message ?? "?")
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "erro desconhecido"
            let code = error?["code"] as? String ?? ""
            NSLog("Lupa legenda: erro da OpenAI %@: %@", code, message)
            // Commit sem áudio suficiente não é falha da sessão.
            if code == "input_audio_buffer_commit_empty" { return }
            onError?(TranscriberError.server(message))
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        NSLog("Lupa legenda: conexão caiu: %@", error.localizedDescription)
        close()
        onError?(error)
    }

    private func markOpen() {
        guard !opened else { return }
        opened = true
        onOpen?()
    }

    // O áudio pode seguir assim que o socket abre: o session.update já foi na frente, na mesma fila.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("Lupa legenda: conectado à OpenAI")
        markOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard !closed else { return }
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        NSLog("Lupa legenda: OpenAI fechou (%ld) %@", closeCode.rawValue, text)
        closed = true
        onError?(TranscriberError.closed(text.isEmpty ? "A OpenAI encerrou a transcrição (código \(closeCode.rawValue))." : text))
    }

    // Chave errada responde 401 no aperto de mão, antes de qualquer evento.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !closed else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        NSLog("Lupa legenda: conexão terminou (HTTP %ld) %@", status, error?.localizedDescription ?? "")
        if status == 401 {
            closed = true
            onError?(TranscriberError.server("A OpenAI recusou a chave. Confira em Ajustes."))
        } else if let error {
            fail(error)
        }
    }
}
