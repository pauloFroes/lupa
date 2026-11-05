import Foundation

struct CaptionLanguage: Identifiable, Hashable {
    let code: String  // ISO-639-1; vazio deixa a OpenAI detectar
    let name: String
    var id: String { code }

    static let all: [CaptionLanguage] = [
        .init(code: "pt", name: "Português"),
        .init(code: "en", name: "Inglês"),
        .init(code: "es", name: "Espanhol"),
        .init(code: "fr", name: "Francês"),
        .init(code: "it", name: "Italiano"),
        .init(code: "de", name: "Alemão"),
        .init(code: "ja", name: "Japonês"),
        .init(code: "zh", name: "Chinês"),
        .init(code: "", name: "Detectar automaticamente"),
    ]

    static func named(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }
}

// Modelo e ritmo da transcrição. O gpt-live-transcribe mostra o texto enquanto se fala; o `delay`
// troca rapidez por precisão. O gpt-transcribe só devolve a frase inteira depois de cada pausa.
enum TranscriptionChoice: String, Codable, CaseIterable, Identifiable {
    case livePrecise = "live-high"
    case liveBalanced = "live-medium"
    case liveFast = "live-low"
    case wholeSentence = "transcribe"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .livePrecise: "gpt-live-transcribe · máxima precisão"
        case .liveBalanced: "gpt-live-transcribe · equilibrado"
        case .liveFast: "gpt-live-transcribe · mais rápido"
        case .wholeSentence: "gpt-transcribe · frase inteira após a pausa"
        }
    }

    var model: String { self == .wholeSentence ? "gpt-transcribe" : "gpt-live-transcribe" }

    var delay: String? {
        switch self {
        case .livePrecise: "high"
        case .liveBalanced: "medium"
        case .liveFast: "low"
        case .wholeSentence: nil
        }
    }
}

struct CaptionOptions: Codable, Equatable {
    enum Size: String, Codable, CaseIterable {
        case small, medium, large

        var label: String {
            switch self {
            case .small: "Pequena"
            case .medium: "Média"
            case .large: "Grande"
            }
        }

        var points: CGFloat {
            switch self {
            case .small: 22
            case .medium: 30
            case .large: 40
            }
        }
    }

    // Liga a legenda sozinha ao entrar no Ao vivo (e, portanto, ao gravar).
    var onLive = false
    var language = "pt"
    var size: Size = .medium
    // Salva a transcrição em texto (.txt) e, na gravação, a legenda (.srt) ao lado do vídeo.
    var saveTranscript = true
    // Termos que a transcrição deve acertar (nomes, siglas), passados como dica ao modelo.
    var vocabulary = ""
    // Revisor: um modelo de texto rápido corrige palavras e pontuação de cada frase já fechada.
    var review = true
    // Padrão: o mais preciso. O revisor vazio escolhe sozinho o melhor modelo da conta.
    var transcription: TranscriptionChoice = .livePrecise
    var reviewModel = ""

    init() {}

    // Campo novo não pode zerar os ajustes já salvos: o que faltar fica no padrão.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = CaptionOptions()
        onLive = try c.decodeIfPresent(Bool.self, forKey: .onLive) ?? base.onLive
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? base.language
        size = try c.decodeIfPresent(Size.self, forKey: .size) ?? base.size
        saveTranscript = try c.decodeIfPresent(Bool.self, forKey: .saveTranscript) ?? base.saveTranscript
        vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? base.vocabulary
        review = try c.decodeIfPresent(Bool.self, forKey: .review) ?? base.review
        transcription = (try? c.decodeIfPresent(TranscriptionChoice.self, forKey: .transcription)) ?? base.transcription
        reviewModel = try c.decodeIfPresent(String.self, forKey: .reviewModel) ?? base.reviewModel
    }
}
