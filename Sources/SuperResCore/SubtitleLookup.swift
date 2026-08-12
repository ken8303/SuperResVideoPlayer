import Foundation

/// Fast lookup for time-ordered subtitle cues. A full-length transcription
/// can contain thousands of cues, and playback queries this several times per
/// second, so scanning from the beginning on every clock tick is unnecessary.
public enum SubtitleLookup {
    /// Returns the most recently started cue containing `time`. When two cues
    /// touch or overlap, the newer cue wins at its start boundary.
    public static func cue(at time: TimeInterval, in cues: [SubtitleCue]) -> SubtitleCue? {
        guard time.isFinite, !cues.isEmpty else { return nil }

        var lower = 0
        var upper = cues.count
        // Upper-bound search: first cue whose start is greater than `time`.
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].startTime <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        guard lower > 0 else { return nil }
        let candidate = cues[lower - 1]
        return time <= candidate.endTime ? candidate : nil
    }
}
