import Foundation

// Segundo passo da legenda: cada frase que a transcrição fecha vai para um modelo de texto pequeno
// e rápido, com as frases anteriores e os termos dos Ajustes, e volta com palavras e pontuação
// corrigidas. A legenda não espera por ele: a frase aparece na hora e é trocada quando a revisão
// chega (~0,5 a 1 s). Se o modelo não existir na conta, tenta o próximo da lista.
final class CaptionReviser {
    private static let models = ["gpt-5-nano", "gpt-4.1-nano", "gpt-4o-mini"]
    private var modelIndex = 0
    private var disabled = false

    func review(_ sentence: String, context: [String], vocabulary: String, language: String, key: String) async -> String? {
        guard !disabled, sentence.count >= 4 else { return nil }
        while modelIndex < Self.models.count {
            let model = Self.models[modelIndex]
            switch await request(model: model, sentence: sentence, context: context, vocabulary: vocabulary, language: language, key: key) {
            case let .text(result):
                return Self.accept(result, original: sentence)
            case .unknownModel:
                NSLog("Lupa legenda: revisor sem o modelo %@, tentando o próximo", model)
                modelIndex += 1
            case .failed:
                return nil
            }
        }
        disabled = true
        NSLog("Lupa legenda: revisor desligado, nenhum modelo da lista respondeu")
        return nil
    }

    private enum Outcome {
        case text(String)
        case unknownModel
        case failed
    }

    private func request(model: String, sentence: String, context: [String], vocabulary: String, language: String, key: String) async -> Outcome {
        var lines = [
            "Você revisa legendas de uma aula ao vivo transcritas automaticamente\(language.isEmpty ? "" : " (idioma: \(CaptionLanguage.named(language)))").",
            "Corrija só erros claros: palavras mal reconhecidas (pelo contexto e pelos termos), pontuação, acentos e maiúsculas.",
            "Não reescreva o estilo, não resuma, não complete ideias, não traduza e não acrescente nada.",
            "Responda apenas com a frase corrigida, sem aspas.",
        ]
        let terms = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { lines.append("Termos que aparecem na aula: \(terms)") }
        var input = ""
        if !context.isEmpty { input += "Frases anteriores (só contexto):\n\(context.joined(separator: "\n"))\n\n" }
        input += "Frase a revisar:\n\(sentence)"

        var body: [String: Any] = [
            "model": model,
            "instructions": lines.joined(separator: "\n"),
            "input": input,
            "max_output_tokens": 400,
            "store": false,
        ]
        if model.hasPrefix("gpt-5") { body["reasoning"] = ["effort": "minimal"] }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard status == 200 else {
                let error = json["error"] as? [String: Any]
                let message = error?["message"] as? String ?? ""
                let code = error?["code"] as? String ?? ""
                NSLog("Lupa legenda: revisor %@ respondeu %ld %@ %@", model, status, code, message)
                if status == 404 || code == "model_not_found" || (status == 400 && message.contains("model")) { return .unknownModel }
                return .failed
            }
            guard let text = Self.outputText(json) else { return .failed }
            NSLog("Lupa legenda: revisão em %.2f s", Date().timeIntervalSince(started))
            return .text(text)
        } catch {
            NSLog("Lupa legenda: revisor falhou: %@", error.localizedDescription)
            return .failed
        }
    }

    private static func outputText(_ json: [String: Any]) -> String? {
        if let text = json["output_text"] as? String { return text }
        let output = json["output"] as? [[String: Any]] ?? []
        let texts = output
            .filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined()
    }

    // Uma revisão que muda demais a frase é descartada: o revisor só pode corrigir, não reescrever.
    private static func accept(_ result: String, original: String) -> String? {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !text.isEmpty, text != original else { return nil }
        let ratio = Double(text.count) / Double(max(1, original.count))
        guard ratio > 0.7, ratio < 1.35 else {
            NSLog("Lupa legenda: revisão descartada (mudou demais)")
            return nil
        }
        return text
    }
}
