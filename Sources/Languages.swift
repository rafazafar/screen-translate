import Foundation

struct Language {
    let name: String
    let code: String            // BCP-47 identifier for the Translation framework
    let visionCodes: [String]   // preferred OCR languages (filtered against what Vision supports)
}

enum Languages {
    static let all: [Language] = [
        Language(name: "Japanese", code: "ja", visionCodes: ["ja-JP"]),
        Language(name: "English", code: "en", visionCodes: ["en-US"]),
        Language(name: "Chinese (Simplified)", code: "zh-Hans", visionCodes: ["zh-Hans"]),
        Language(name: "Chinese (Traditional)", code: "zh-Hant", visionCodes: ["zh-Hant"]),
        Language(name: "Korean", code: "ko", visionCodes: ["ko-KR"]),
        Language(name: "French", code: "fr", visionCodes: ["fr-FR"]),
        Language(name: "German", code: "de", visionCodes: ["de-DE"]),
        Language(name: "Spanish", code: "es", visionCodes: ["es-ES"]),
        Language(name: "Italian", code: "it", visionCodes: ["it-IT"]),
        Language(name: "Portuguese", code: "pt", visionCodes: ["pt-BR"]),
        Language(name: "Russian", code: "ru", visionCodes: ["ru-RU"]),
    ]

    static func find(_ code: String) -> Language {
        all.first { $0.code == code } ?? all[0]
    }
}
