import XCTest
@testable import SuperResCore

final class SubtitleLookupTests: XCTestCase {
    private let cues = [
        SubtitleCue(startTime: 1, endTime: 2, text: "one"),
        SubtitleCue(startTime: 3, endTime: 4, text: "two"),
        SubtitleCue(startTime: 4, endTime: 5, text: "three")
    ]

    func testFindsCueWithinItsTimeRange() {
        XCTAssertEqual(SubtitleLookup.cue(at: 1.5, in: cues)?.text, "one")
        XCTAssertEqual(SubtitleLookup.cue(at: 3.5, in: cues)?.text, "two")
    }

    func testReturnsNilBeforeBetweenAndAfterCues() {
        XCTAssertNil(SubtitleLookup.cue(at: 0.5, in: cues))
        XCTAssertNil(SubtitleLookup.cue(at: 2.5, in: cues))
        XCTAssertNil(SubtitleLookup.cue(at: 6, in: cues))
    }

    func testNewCueWinsAtSharedBoundary() {
        XCTAssertEqual(SubtitleLookup.cue(at: 4, in: cues)?.text, "three")
    }

    func testOverlappingCuesPreferMostRecentlyStartedCue() {
        let overlapping = [
            SubtitleCue(startTime: 0, endTime: 3, text: "old"),
            SubtitleCue(startTime: 2, endTime: 4, text: "new")
        ]
        XCTAssertEqual(SubtitleLookup.cue(at: 2.5, in: overlapping)?.text, "new")
    }

    func testEmptyAndNonFiniteInputReturnNil() {
        XCTAssertNil(SubtitleLookup.cue(at: 1, in: []))
        XCTAssertNil(SubtitleLookup.cue(at: .nan, in: cues))
        XCTAssertNil(SubtitleLookup.cue(at: .infinity, in: cues))
    }
}
