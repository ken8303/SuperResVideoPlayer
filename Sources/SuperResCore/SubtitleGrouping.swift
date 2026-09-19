import Foundation

/// One transcribed word with its position in the audio timeline — the
/// common currency both speech engines are reduced to.
public struct WordTiming: Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Pure logic that groups word-level timings into readable subtitle cues.
/// Kept dependency-free (Foundation only) so it can be unit-tested.
public enum SubtitleGrouping {

    /// CJK-family languages aren't space-delimited — joining their "words"
    /// with spaces produces unnatural subtitles, so they use an empty
    /// separator. `code` is a locale/language identifier (e.g. "ja-JP").
    public static func wordSeparator(forLanguageCode code: String) -> String {
        let language = code.prefix(2).lowercased()
        return ["zh", "ja", "th"].contains(language) ? "" : " "
    }

    /// Groups word-level timings into readable subtitle cues. A new cue
    /// starts after a pause longer than `pauseThreshold`, once the cue would
    /// exceed the character budget (~two subtitle lines; halved for CJK
    /// since those glyphs are double-width), or once it would span more than
    /// `maxCueDuration` seconds. A simple heuristic, not a sentence
    /// segmenter — cue breaks won't always land on natural boundaries.
    public static func buildCues(from words: [WordTiming], joiningWith separator: String) -> [SubtitleCue] {
        guard !words.isEmpty else { return [] }

        let maxCueDuration: TimeInterval = 6.0
        let maxCueChars = separator.isEmpty ? 32 : 84
        let pauseThreshold: TimeInterval = 0.35
        let trailingPadding: TimeInterval = 0.15

        var cues: [SubtitleCue] = []
        var currentWords: [WordTiming] = []

        func flush(before nextStart: TimeInterval? = nil) {
            guard let first = currentWords.first, let last = currentWords.last else { return }
            let text = currentWords.map(\.text).joined(separator: separator)
            let paddedEnd = last.end + trailingPadding
            // A length/duration split can happen even when the next word
            // starts almost immediately. Do not let display padding overlap
            // that next cue, because the overlay resolves overlaps by taking
            // the first matching cue.
            let end = nextStart.map { max(first.start, min(paddedEnd, $0)) } ?? paddedEnd
            cues.append(SubtitleCue(startTime: first.start, endTime: end, text: text))
            currentWords.removeAll()
        }

        for word in words {
            if let last = currentWords.last, let first = currentWords.first {
                let gap = word.start - last.end
                let projectedChars = (currentWords.map(\.text) + [word.text])
                    .joined(separator: separator).count
                let projectedDuration = word.end - first.start

                if gap > pauseThreshold || projectedChars > maxCueChars || projectedDuration > maxCueDuration {
                    flush(before: word.start)
                }
            }
            currentWords.append(word)
        }
        flush()

        return cues
    }
}
