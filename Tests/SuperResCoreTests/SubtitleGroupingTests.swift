import XCTest
@testable import SuperResCore

final class SubtitleGroupingTests: XCTestCase {

    func testWordSeparatorForCJKIsEmpty() {
        XCTAssertEqual(SubtitleGrouping.wordSeparator(forLanguageCode: "ja-JP"), "")
        XCTAssertEqual(SubtitleGrouping.wordSeparator(forLanguageCode: "zh-TW"), "")
        XCTAssertEqual(SubtitleGrouping.wordSeparator(forLanguageCode: "ko-KR"), "")
        XCTAssertEqual(SubtitleGrouping.wordSeparator(forLanguageCode: "th"), "")
    }

    func testWordSeparatorForSpaceDelimitedIsSpace() {
        XCTAssertEqual(SubtitleGrouping.wordSeparator(forLanguageCode: "en-US"), " ")
        XCTAssertEqual(SubtitleGrouping.wordSeparator(forLanguageCode: "fr-FR"), " ")
    }

    func testEmptyWordsProduceNoCues() {
        XCTAssertTrue(SubtitleGrouping.buildCues(from: [], joiningWith: " ").isEmpty)
    }

    func testWordsJoinIntoASingleCue() {
        let words = [
            WordTiming(text: "Hello", start: 0.0, end: 0.4),
            WordTiming(text: "there", start: 0.5, end: 0.9)
        ]
        let cues = SubtitleGrouping.buildCues(from: words, joiningWith: " ")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello there")
        XCTAssertEqual(cues[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(cues[0].endTime, 0.9 + 0.15, accuracy: 0.0001) // trailing padding
    }

    func testPauseSplitsCues() {
        // A gap larger than the 0.35s pause threshold starts a new cue.
        let words = [
            WordTiming(text: "First", start: 0.0, end: 0.3),
            WordTiming(text: "Second", start: 1.5, end: 1.9)
        ]
        let cues = SubtitleGrouping.buildCues(from: words, joiningWith: " ")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "First")
        XCTAssertEqual(cues[1].text, "Second")
    }

    func testDurationCapSplitsCues() {
        // Spanning more than 6s forces a break even without a pause.
        let words = [
            WordTiming(text: "a", start: 0.0, end: 0.1),
            WordTiming(text: "b", start: 0.2, end: 6.5)
        ]
        let cues = SubtitleGrouping.buildCues(from: words, joiningWith: " ")
        XCTAssertEqual(cues.count, 2)
    }

    func testLengthSplitDoesNotOverlapNextCue() {
        let words = [
            WordTiming(text: String(repeating: "a", count: 50), start: 0, end: 1),
            WordTiming(text: String(repeating: "b", count: 50), start: 1.05, end: 2)
        ]

        let cues = SubtitleGrouping.buildCues(from: words, joiningWith: " ")

        XCTAssertEqual(cues.count, 2)
        XCTAssertLessThanOrEqual(cues[0].endTime, cues[1].startTime)
        XCTAssertEqual(cues[0].endTime, 1.05, accuracy: 0.0001)
    }
}
