import XCTest
@testable import SuperResCore

final class VideoMathTests: XCTestCase {

    // MARK: Pixel-format bit depth
    //
    // mpv exposes no bit-depth property, so this parse is the only thing
    // standing between the UI and claiming a 10-bit HDR source is 8-bit.

    func testBitDepthOfCommonSDRFormats() {
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuv420p"), 8)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuvj420p"), 8)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "rgb24"), 8)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "bgra"), 8)
    }

    func testBitDepthOfHDRFormats() {
        // The user-facing case: HDR10 in HEVC Main 10.
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuv420p10le"), 10)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuv422p10le"), 10)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuva420p10le"), 10)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuv444p12le"), 12)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "gbrp16le"), 16)
    }

    func testBitDepthOfVideoToolboxBiplanarFormats() {
        // "p010" has no plane suffix to skip — the digits follow "p" directly.
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "p010"), 10)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "p010le"), 10)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "nv12"), 8)  // no "p" at all
    }

    func testSubsamplingDigitsAreNotMistakenForDepth() {
        // Regression: a naive "contains 10" check reads yuv410p as 10-bit.
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuv410p"), 8)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "yuv411p"), 8)
    }

    func testBitDepthFallsBackForMissingOrOddInput() {
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: nil), 8)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: ""), 8)
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "p999"), 8)   // out of range
        XCTAssertEqual(VideoMath.bitDepth(fromPixelFormat: "p"), 8)      // trailing "p"
    }

    // MARK: Bitrate

    func testBitrateScalesWithPixelsAndFPS() {
        let sd = VideoMath.recommendedBitrate(width: 640, height: 360, fps: 30)
        let hd = VideoMath.recommendedBitrate(width: 1920, height: 1080, fps: 30)
        XCTAssertGreaterThan(hd, sd)  // more pixels → higher bitrate
    }

    func testBitrateClampsToFloor() {
        // Tiny frame would compute below 2 Mbps → clamped to the floor.
        XCTAssertEqual(VideoMath.recommendedBitrate(width: 64, height: 64, fps: 1), 2_000_000)
    }

    func testBitrateClampsToCeiling() {
        // 8K at high fps would exceed 80 Mbps → clamped to the ceiling.
        let huge = VideoMath.recommendedBitrate(width: 8192, height: 4096, fps: 60)
        XCTAssertEqual(huge, 80_000_000)
    }

    func testUpscaleFactorUnclampedForSmallFrames() {
        // 1080p × 2 = 3840×2160, well within the 16384 limit.
        let f = VideoMath.clampedUpscaleFactor(inputWidth: 1920, inputHeight: 1080, requestedFactor: 2.0)
        XCTAssertEqual(f, 2.0, accuracy: 0.0001)
    }

    func testUpscaleFactorClampedForLargeFrames() {
        // 8192 wide × 2 = 16384 = the limit exactly → factor stays 2.0.
        let atLimit = VideoMath.clampedUpscaleFactor(inputWidth: 8192, inputHeight: 4096, requestedFactor: 2.0)
        XCTAssertEqual(atLimit, 2.0, accuracy: 0.0001)

        // 10000 wide × 2 = 20000 > 16384 → clamped below 2.0.
        let clamped = VideoMath.clampedUpscaleFactor(inputWidth: 10000, inputHeight: 4000, requestedFactor: 2.0)
        XCTAssertLessThan(clamped, 2.0)
        XCTAssertEqual(clamped, 16384.0 / 10000.0, accuracy: 0.0001)
    }

    func testUpscaleFactorHandlesZeroSizeSafely() {
        XCTAssertEqual(VideoMath.clampedUpscaleFactor(inputWidth: 0, inputHeight: 0, requestedFactor: 1.5), 1.5)
    }
}
