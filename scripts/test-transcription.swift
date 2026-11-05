// Testa a transcrição em tempo real da OpenAI fora do app, com a mesma conversa que a Lupa usa.
// Uso: scripts/test-transcription.swift [arquivo.wav]  (PCM 16 bits, mono, 24 kHz)
// Sem arquivo, gera uma frase com o `say`. A chave vem de OPENAI_API_KEY ou do chaveiro da Lupa.
import Foundation

func run(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    ?? run("/usr/bin/security", ["find-generic-password", "-s", "io.github.paulofroes.lupa", "-a", "openai-api-key", "-w"])
guard !key.isEmpty else { print("sem chave"); exit(1) }

var wav = CommandLine.arguments.dropFirst().first
if wav == nil {
    let out = NSTemporaryDirectory() + "lupa-teste.wav"
    _ = run("/usr/bin/say", ["-v", "Luciana", "-o", out, "--data-format=LEI16@24000",
                             "Olá, este é um teste da legenda ao vivo da Lupa. Agora uma pausa.  E depois a segunda frase."])
    wav = out
}
guard let data = FileManager.default.contents(atPath: wav!), data.count > 44 else { print("sem áudio"); exit(1) }
let pcm = data.subdata(in: 44 ..< data.count)

var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
let task = URLSession.shared.webSocketTask(with: request)
task.resume()
let start = Date()
func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(start)) }
func send(_ event: [String: Any]) {
    let text = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    task.send(.string(text)) { if let error = $0 { print(stamp(), "erro ao enviar:", error) } }
}
func receive() {
    task.receive { result in
        switch result {
        case let .success(.string(text)):
            let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            let type = event["type"] as? String ?? "?"
            let detail = event["delta"] ?? event["transcript"] ?? event["error"] ?? ""
            print(stamp(), type, detail)
            receive()
        case let .success(other):
            print(stamp(), "outro:", other)
            receive()
        case let .failure(error):
            print(stamp(), "conexão:", error, (task.response as? HTTPURLResponse)?.statusCode ?? 0)
            exit(0)
        }
    }
}
send([
    "type": "session.update",
    "session": [
        "type": "transcription",
        "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": ["model": "gpt-live-transcribe", "delay": "low", "languages": ["pt"]],
            "turn_detection": NSNull(),
        ]],
    ],
])
receive()
// Envia em tempo real (100 ms por bloco) e fecha o turno no fim, como a Lupa faz numa pausa.
DispatchQueue.global().async {
    let chunk = 4800
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunk, pcm.count)
        send(["type": "input_audio_buffer.append", "audio": pcm.subdata(in: offset ..< end).base64EncodedString()])
        offset = end
        Thread.sleep(forTimeInterval: 0.1)
    }
    print(stamp(), "fim do áudio; commit")
    send(["type": "input_audio_buffer.commit"])
    Thread.sleep(forTimeInterval: 6)
    exit(0)
}
RunLoop.main.run()
