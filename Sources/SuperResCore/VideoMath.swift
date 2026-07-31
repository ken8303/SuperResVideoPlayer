import Foundation

/// Pure numeric helpers for the video pipeline, extracted so the "magic
/// number" formulas can be unit-tested independently of Metal/AVFoundation.
public enum VideoMath {

    /// Metal 2D-texture side limit on Apple-family GPUs.
    public static let maxTextureDimension = 16384

    /// A target average bitrate for the HEVC export, scaled by pixel count
    /// and frame rate (~0.07 bits per pixel per second), clamped to a sane
    /// range. Used by `VideoExporter`.
    public static func recommendedBitrate(width: Int, height: Int, fps: Double) -> Int {
        let raw = Double(width * height) * fps * 0.07
        return min(80_000_000, max(2_000_000, Int(raw)))
    }

    /// Clamps a requested upscale factor so the output never exceeds the
    /// GPU's texture-dimension limit. Returns a factor `<= requested` (and
    /// `<= 1` means "already at/over the limit — don't upscale"). Used by
    /// the Super Resolution and Neural-enhancer paths.
    public static func clampedUpscaleFactor(inputWidth: Int, inputHeight: Int,
                                            requestedFactor: Double,
                                            maxDimension: Int = maxTextureDimension) -> Double {
        guard inputWidth > 0, inputHeight > 0 else { return requestedFactor }
        let limit = min(Double(maxDimension) / Double(inputWidth),
                        Double(maxDimension) / Double(inputHeight))
        return min(requestedFactor, limit)
    }

    /// Bits per component, parsed from an FFmpeg/mpv pixel-format name.
    ///
    /// mpv exposes no bit-depth property (`video-params/average-bpp` is bits
    /// per *pixel* averaged over subsampled planes, which is a different
    /// number), so the depth has to come from the format name. It follows the
    /// plane marker: "yuv420p10le" → 10, "p010" → 10, "gbrp12le" → 12, while
    /// 8-bit formats carry no suffix ("yuv420p" → 8).
    ///
    /// Scanning *after* a "p" rather than searching for "10" anywhere is what
    /// keeps subsampling digits from being misread — "yuv410p" is 8-bit.
    public static func bitDepth(fromPixelFormat format: String?) -> Int {
        guard let format, !format.isEmpty else { return 8 }
        var found: Int?
        var index = format.startIndex
        while index < format.endIndex {
            guard format[index] == "p" else {
                index = format.index(after: index)
                continue
            }
            var digits = ""
            var scan = format.index(after: index)
            while scan < format.endIndex, format[scan].isNumber {
                digits.append(format[scan])
                scan = format.index(after: scan)
            }
            if let value = Int(digits) { found = value }
            index = scan > index ? scan : format.index(after: index)
        }
        guard let found, (8...16).contains(found) else { return 8 }
        return found
    }
}
