import XCTest
@testable import SuperResCore

final class TranslationResponseParserTests: XCTestCase {

    func testParsesPipeSeparatedLines() {
        let content = "1|Hello\n2|World"
        let result = TranslationResponseParser.parse(content)
        XCTAssertEqual(result[1], "Hello")
        XCTAssertEqual(result[2], "World")
        XCTAssertEqual(result.count, 2)
    }

    func testAcceptsFullWidthSeparators() {
        // Chinese/Japanese output often uses full-width separators/numbers.
        let content = "1：你好\n2｜世界"
        let result = TranslationResponseParser.parse(content)
        XCTAssertEqual(result[1], "你好")
        XCTAssertEqual(result[2], "世界")
    }

    func testSkipsUnparseableAndEmptyLines() {
        let content = "1|Good\ngarbage line\n2|\n3|Fine"
        let result = TranslationResponseParser.parse(content)
        XCTAssertEqual(result[1], "Good")
        XCTAssertNil(result[2])       // empty text skipped
        XCTAssertEqual(result[3], "Fine")
    }

    func testStripNumberPrefixRemovesLeadingNumber() {
        XCTAssertEqual(TranslationResponseParser.stripNumberPrefix("2|translated"), "translated")
        XCTAssertEqual(TranslationResponseParser.stripNumberPrefix("10: text"), "text")
    }

    func testStripNumberPrefixLeavesPlainTextAlone() {
        XCTAssertEqual(TranslationResponseParser.stripNumberPrefix("just text"), "just text")
        // A number that isn't a prefix separator stays intact.
        XCTAssertEqual(TranslationResponseParser.stripNumberPrefix("42 apples"), "42 apples")
    }
}
