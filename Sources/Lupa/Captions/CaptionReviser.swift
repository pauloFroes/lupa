import Foundation

// Modelos de texto da conta da OpenAI, para o seletor do revisor. A lista vem de /v1/models, então
// modelos novos aparecem sem atualizar a Lupa. "Melhor" é a versão mais alta do modelo cheio
// (sem mini/nano); os "pro" ficam de fora por demorarem demais para legenda ao vivo.
enum ModelCatalog {
    private static var cache: [String]?

    static func textModels(key: String) async -> [String] {
        if let cache { return cache }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        let models = items.compactMap { $0["id"] as? String }.filter(isTextModel)
            .sorted { score($0) == score($1) ? $0 < $1 : score($0) > score($1) }
        cache = models
        return models
    }

    static func best(key: String) async -> String? {
        await textModels(key: key).first
    }

    private static let excluded = ["audio", "realtime", "transcribe", "tts", "image", "search", "embedding",
                                   "codex", "instruct", "moderation", "-pro", "preview", "oss", "computer", "deep-research"]

    private static func isTextModel(_ id: String) -> Bool {
        guard id.hasPrefix("gpt-"), version(id) != nil else { return false }
        if excluded.contains(where: id.contains) { return false }
        // Instantâneos datados (gpt-5-2025-08-07) repetem o modelo base.
        return id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
            && id.range(of: #"-\d{4}$"#, options: .regularExpression) == nil
    }

    private static func version(_ id: String) -> Double? {
        guard let range = id.range(of: #"^gpt-(\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
        return Double(id[range].dropFirst(4))
    }

    private static func score(_ id: String) -> Double {
        let size = id.contains("nano") ? 0.0 : id.contains("mini") ? 1.0 : 2.0
        let latest = id.contains("chat-latest") ? -0.5 : 0
        return (version(id) ?? 0) * 10 + size + latest
    }
}

// Segundo passo da legenda: cada frase que a transcrição fecha vai para um modelo de texto, com as
// frases anteriores e os termos dos Ajustes, e volta com palavras e pontuação corrigidas. A legenda
// não espera por ele: a frase aparece na hora e é trocada quando a revisão chega. O modelo é o dos
// Ajustes; no automático, o melhor da conta. Se ele falhar, tenta os rápidos da lista de reserva.
final class CaptionReviser {
    private static let fallbacks = ["gpt-5-nano", "gpt-4.1-nano", "gpt-4o-mini"]
    private var unavailable = Set<String>()
    // Variante do parâmetro de raciocínio que cada modelo aceita (índice em `reasoningVariants`).
    private var reasoning: [String: Int] = [:]
    private static let reasoningVariants: [String?] = ["none", "minimal", nil]

    func review(_ sentence: String, context: [String], vocabulary: String, language: String, model chosen: String, key: String) async -> String? {
        guard sentence.count >= 4 else { return nil }
        var candidates: [String] = []
        if !chosen.isEmpty {
            candidates.append(chosen)
        } else if let best = await ModelCatalog.best(key: key) {
            candidates.append(best)
        }
        candidates += Self.fallbacks.filter { !candidates.contains($0) }
        for model in candidates where !unavailable.contains(model) {
            switch await request(model: model, sentence: sentence, context: context, vocabulary: vocabulary, language: language, key: key) {
            case let .text(result):
                return Self.accept(result, original: sentence)
            case .unknownModel:
                NSLog("Lupa legenda: revisor sem o modelo %@", model)
                unavailable.insert(model)
            case .failed:
                return nil
            }
        }
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

        var variant = reasoning[model] ?? (model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") ? 0 : 2)
        while variant < Self.reasoningVariants.count {
            var body: [String: Any] = [
                "model": model,
                "instructions": lines.joined(separator: "\n"),
                "input": input,
                "max_output_tokens": 600,
                "store": false,
            ]
            if let effort = Self.reasoningVariants[variant] { body["reasoning"] = ["effort": effort] }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 6
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let started = Date()
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if status == 200, let text = Self.outputText(json) {
                    reasoning[model] = variant
                    NSLog("Lupa legenda: revisão com %@ em %.2f s", model, Date().timeIntervalSince(started))
                    return .text(text)
                }
                let error = json["error"] as? [String: Any]
                let message = error?["message"] as? String ?? ""
                let code = error?["code"] as? String ?? ""
                let param = error?["param"] as? String ?? ""
                NSLog("Lupa legenda: revisor %@ respondeu %ld %@ %@", model, status, code, message)
                if status == 400, param.contains("reasoning") || message.contains("reasoning") {
                    variant += 1
                    continue
                }
                if status == 404 || code == "model_not_found" || (status == 400 && message.contains("model")) { return .unknownModel }
                return .failed
            } catch {
                NSLog("Lupa legenda: revisor falhou: %@", error.localizedDescription)
                return .failed
            }
        }
        return .failed
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
