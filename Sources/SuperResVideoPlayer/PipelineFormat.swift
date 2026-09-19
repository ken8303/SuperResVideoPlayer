import CoreVideo
import Metal

/// The pixel format the **playback** pipeline runs at, in one place so the
/// three representations can never drift apart: what mpv is asked to write,
/// what CoreVideo allocates, and what Metal sees.
///
/// History: this pipeline was 8-bit BGRA, which forced HDR to be tone-mapped
/// to SDR before MetalFX ever saw a frame — libmpv's software render API
/// documents only 8-bit output formats ("rgb0", "bgr0", "0bgr", "0rgb").
/// But the header also allows undocumented internal format names, and a
/// runtime probe against this build showed `rgba64` is accepted and writes
/// real pixel data. At 16 bits per channel there is enough precision to
/// carry an HDR signal into the Metal pipeline, so enhancement and high
/// dynamic range stop being mutually exclusive.
///
/// The **export** path deliberately stays 8-bit: it encodes to SDR HEVC, so
/// the extra precision would cost bandwidth for nothing.
enum PipelineFormat {

    /// What `MPV_RENDER_PARAM_SW_FORMAT` is set to. Undocumented but probed
    /// as working; `verifySupport` re-checks at runtime rather than assuming.
    static let mpvSoftwareFormat = "rgba64le"

    /// R,G,B,A × 16-bit little-endian — the CoreVideo layout matching
    /// `mpvSoftwareFormat` byte for byte.
    static let coreVideo: OSType = kCVPixelFormatType_64RGBALE

    /// The Metal view of the same memory. Used for every *texture* in the
    /// pipeline — the frame wrap, MetalFX in/out, warp and enhance targets.
    static let metal: MTLPixelFormat = .rgba16Unorm

    /// The format of the screen drawable, which is a different question:
    /// `CAMetalLayer` accepts only a small set of pixel formats, and
    /// `rgba16Unorm` is **not** among them — assigning it traps at runtime.
    ///
    /// The right choice also depends on how the values are *encoded*:
    ///
    /// - **HDR (`rgb10a2Unorm`)** — paired with a PQ colour space this is
    ///   literally HDR10: 10-bit PQ, which is what the format was designed
    ///   for and what broadcast HDR uses. `rgba16Float` looks like the
    ///   "better" choice but is wrong here, because Apple's EDR model treats
    ///   float drawables as *extended linear*, so PQ-encoded values get
    ///   decoded with the wrong curve — which lifts shadows and flattens
    ///   contrast.
    /// - **SDR (`bgra8Unorm`)** — the long-standing default.
    ///
    /// The fragment shader emits `float4`, so it feeds either correctly no
    /// matter which format the sampled texture happens to be.
    /// One format for both SDR and HDR, deliberately. It must be 10-bit
    /// unorm for PQ to decode correctly, and it is also a perfectly good SDR
    /// drawable (10 bits beats the old 8). Keeping it *constant* matters:
    /// changing `MTKView.colorPixelFormat` on a live view makes SwiftUI tear
    /// the representable down and build a new coordinator, leaking a texture
    /// cache and scaler each time. Only the colour space changes now.
    static let drawable: MTLPixelFormat = .rgb10a2Unorm

    // MARK: 8-bit fallback

    /// If a machine's libmpv rejects the 16-bit format (it is undocumented,
    /// so a future build could drop it), the player falls back to these and
    /// behaves exactly as it did before.
    enum Fallback {
        static let mpvSoftwareFormat = "bgr0"
        static let coreVideo: OSType = kCVPixelFormatType_32BGRA
        static let metal: MTLPixelFormat = .bgra8Unorm
    }
}
