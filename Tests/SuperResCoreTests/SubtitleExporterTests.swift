import XCTest
@testable import SuperResCore

final class SubtitleExporterTests: XCTestCase {

    func testTimestampFormatting() {
        XCTAssertEqual(SubtitleExporter.timestamp(0), "00:00:00,000")
        XCTAssertEqual(SubtitleExporter.timestamp(1.5), "00:00:01,500")
        XCTAssertEqual(SubtitleExporter.timestamp(61.25), "00:01:01,250")
        XCTAssertEqual(SubtitleExporter.timestamp(3661.001), "01:01:01,001")
        // Negative times clamp to zero.
        XCTAssertEqual(SubtitleExporter.timestamp(-5), "00:00:00,000")
    }

    func testSRTStructure() {
        let cues = [
            SubtitleCue(startTime: 0, endTime: 1.5, text: "Hello"),
            SubtitleCue(startTime: 2, endTime: 3, text: "World")
        ]
        let srt = SubtitleExporter.srt(from: cues)
        let expected = """
        1
        00:00:00,000 --> 00:00:01,500
        Hello

        2
        00:00:02,000 --> 00:00:03,000
        World

        """
        XCTAssertEqual(srt, expected)
    }

    func testEmptyCuesProduceEmptyString() {
        XCTAssertEqual(SubtitleExporter.srt(from: []), "")
    }

    func testCueEqualityIgnoresID() {
        // Two cues with identical content but different ids compare equal.
        let a = SubtitleCue(startTime: 1, endTime: 2, text: "same")
        let b = SubtitleCue(startTime: 1, endTime: 2, text: "same")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.id, b.id)
    }
}
