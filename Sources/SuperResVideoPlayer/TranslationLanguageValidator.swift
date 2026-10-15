import Foundation
import NaturalLanguage

/// Conservative output checks; short names and shared CJK ideographs cannot
/// reliably identify a language, so only clear mismatches are rejected.
enum TranslationLanguageValidator {
    static func accepts(_ text: String, target: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("|"), !text.contains("｜"),
              !text.contains("```"), !text.contains("{"), !text.contains("}") else { return false }
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        let han = scalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
        let kana = scalars.contains { (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9D).contains($0.value) }
        let hangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        let language = target.split(separator: "-").first.map(String.init) ?? target
        switch language {
        case "ja":
            if hangul { return false }
            // Permit brief Latin names/acronyms, but never an English sentence.
            if !kana && !han { return letters.count <= 8 && text.split(whereSeparator: { $0.isWhitespace }).count == 1 }
        case "zh":
            if kana || hangul { return false }
            if !han { return letters.count <= 8 && text.split(whereSeparator: { $0.isWhitespace }).count == 1 }
        case "ko":
            if kana { return false }
            if !hangul { return letters.count <= 8 }
        default:
            if kana || hangul || han { return false }
        }
        guard letters.count >= 20 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first,
           best.value >= 0.8 {
            let detected = best.key.rawValue.split(separator: "-").first.map(String.init)
            return detected == language
        }
        return true
    }
}
