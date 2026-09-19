import Foundation

/// Indexed lookup preserves the first active cue even when padded cues overlap.
struct SubtitleTimeline {
    private let cues: [SubtitleCue]
    private let latestEndThroughCue: [Double]

    init(cues: [SubtitleCue]) {
        self.cues = cues.enumerated().sorted {
            $0.element.startTime == $1.element.startTime
                ? $0.offset < $1.offset
                : $0.element.startTime < $1.element.startTime
        }.map(\.element)
        var latestEnd = -Double.infinity
        latestEndThroughCue = self.cues.map {
            latestEnd = max(latestEnd, $0.endTime)
            return latestEnd
        }
    }

    func text(at time: Double) -> String? {
        guard time.isFinite else { return nil }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if latestEndThroughCue[middle] < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < cues.count, cues[lower].startTime <= time else { return nil }
        return cues[lower].text
    }
}
