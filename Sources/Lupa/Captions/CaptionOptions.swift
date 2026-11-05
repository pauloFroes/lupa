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
}
