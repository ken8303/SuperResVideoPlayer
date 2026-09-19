import Foundation

/// Parses the on-device model's translation output ("N|translation" lines).
/// Pure and dependency-free so the lenient parsing rules can be unit-tested.
public enum TranslationResponseParser {

    /// Separators the model emits between the line number and the text —
    /// ASCII and full-width variants (Chinese/Japanese output often comes
    /// back as "１：…" or "1｜…").
    static let separators: Set<Character> = ["|", ":", ".", "｜", "：", "．", "、"]

    /// Lenient parser for "N|translation" lines (also tolerates "N:" / "N.").
    /// Lines that don't parse are simply skipped — those cues keep their
    /// original text rather than failing the whole batch. Returns a map of
    /// line number → translated text.
    public static func parse(_ content: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separatorIndex = line.firstIndex(where: { separators.contains($0) }) else {
                continue
            }
            let numberPart = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            guard let number = Int(numberPart) else { continue }
            let text = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result[number] = text
            }
        }
        return result
    }

    /// Removes a leading "N|" / "N:" / "N." (ASCII or full-width) that the
    /// model sometimes emits with the wrong number — the strict parser
    /// rejects it, but it shouldn't end up inside a subtitle either.
    public static func stripNumberPrefix(_ line: String) -> String {
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }
        guard index > line.startIndex, index < line.endIndex, separators.contains(line[index]) else {
            return line
        }
        return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    }
}
