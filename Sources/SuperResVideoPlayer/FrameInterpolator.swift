import Metal
import MetalFX

/// Wraps Apple's native MetalFX frame interpolator (`MTLFXFrameInterpolator`,
/// part of Metal 4 / macOS 26+) to generate a single intermediate frame from
/// a `previous`/`current` color pair plus a motion texture and a depth
/// texture.
///
/// IMPORTANT CAVEAT: `MTLFXFrameInterpolator` was designed for game engines,
/// which already produce per-pixel motion vectors and a depth buffer as a
/// side effect of rendering the 3D scene. Video has neither:
///  - Motion vectors here come from `OpticalFlowEstimator` (Vision), not a
///    render engine, so quality depends entirely on how well Vision's flow
///    estimate tracks the actual video content.
///  - There is no real scene depth, so this class hands the interpolator a
///    constant/flat depth texture. Depth is normally used by MetalFX to help
///    resolve disocclusion (areas newly revealed between frames); with a
///    flat depth field it can't do that, so disocclusion artifacts (ghosting
///    around fast-moving edges) are more likely than in a game.
///  - Per Apple's documentation, the interpolator produces exactly ONE
///    intermediate frame per (previous, current) pair — there's no
///    documented way to ask for an arbitrary temporal phase. That's why this
///    project only uses it for the 2x case; 3x falls back to a custom warp
///    (see `Shaders.metal` / `Renderer.swift`).
///
/// The property names below were cross-checked against the actual
/// `MTLFXFrameInterpolator.h`/`MTLFXFrameInterpolatorDescriptor` header diff
/// for the Xcode 26 SDK (found via web search, since this sandbox has no
/// macOS/Metal toolchain to compile against directly), so they should be
/// accurate as of that SDK. Still worth a quick diff against your local
/// `MetalFX.framework/Headers/MTLFXFrameInterpolator.h` if anything fails to
/// compile, since this remains a very new API.
final class FrameInterpolator {

    private let device: MTLDevice
    /// Pixel format of the frames being interpolated (see
    /// EnhancementProcessor for why this is parameterised).
    private let pixelFormat: MTLPixelFormat
    private var interpolator: (any MTLFXFrameInterpolator)?
    private var depthTexture: MTLTexture?
    private var outputTexture: MTLTexture?

    private var configuredWidth = 0
    private var configuredHeight = 0

    /// Set to false the first time `MTLFXFrameInterpolatorDescriptor.supportsDevice`
    /// reports no support, so `Renderer` can stop calling into this class.
    private(set) var isSupported = true

    init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        self.device = device
        self.pixelFormat = pixelFormat
    }

    /// Returns the interpolated midpoint frame between `previous` and
    /// `current`, or nil if unsupported / not yet configured for this size /
    /// no motion texture is available yet.
    func interpolate(
        previous: MTLTexture,
        current: MTLTexture,
        motionTexture: MTLTexture,
        deltaTime: Double,
        clearDepthPipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard isSupported else { return nil }

        if interpolator == nil || configuredWidth != current.width || configuredHeight != current.height {
            guard configure(width: current.width, height: current.height, clearDepthPipeline: clearDepthPipeline, commandBuffer: commandBuffer) else {
                isSupported = false
                return nil
            }
        }

        guard let interpolator, let depthTexture, let outputTexture else { return nil }

        interpolator.colorTexture = current
        interpolator.prevColorTexture = previous
        interpolator.motionTexture = motionTexture
        interpolator.depthTexture = depthTexture
        interpolator.outputTexture = outputTexture

        // Motion vectors from OpticalFlowEstimator are already expressed in
        // full-resolution pixel units, but Vision produces *forward* flow
        // (previous -> current) while MetalFX expects the backward
        // convention — so a scale of -1.0 both interprets the magnitudes at
        // face value and flips the direction (see OpticalFlowEstimator's
        // doc comment on the convention).
        interpolator.motionVectorScaleX = -1.0
        interpolator.motionVectorScaleY = -1.0

        // We always hand the interpolator an explicit, freshly-matched
        // (previous, current) pair rather than relying on it remembering
        // state from an earlier call (we only invoke it for the specific
        // frames that need a midpoint, not every display refresh), so we
        // always ask it to treat this as a fresh history rather than assume
        // continuity with whatever it last saw.
        interpolator.shouldResetHistory = true

        interpolator.deltaTime = Float(deltaTime)

        // This project has no real 3D camera/scene — see the class doc
        // comment. These are plausible placeholder values so the
        // interpolator has *something* internally consistent to reason
        // with; they don't correspond to anything in the source video.
        interpolator.nearPlane = 0.1
        interpolator.farPlane = 1000.0
        interpolator.fieldOfView = 60.0
        interpolator.aspectRatio = Float(current.width) / Float(current.height)
        interpolator.jitterOffsetX = 0
        interpolator.jitterOffsetY = 0

        // Non-reversed depth convention (0 = near, 1 = far), matching the
        // constant value clearDepthKernel writes.
        interpolator.isDepthReversed = false

        interpolator.encode(commandBuffer: commandBuffer)

        return outputTexture
    }

    private func configure(width: Int, height: Int, clearDepthPipeline: MTLComputePipelineState, commandBuffer: MTLCommandBuffer) -> Bool {
        guard MTLFXFrameInterpolatorDescriptor.supportsDevice(device) else {
            print("SuperResVideoPlayer: MetalFX Frame Interpolator is not supported on this GPU/OS. Frame interpolation will be limited to the custom warp fallback.")
            return false
        }

        let descriptor = MTLFXFrameInterpolatorDescriptor()
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.outputWidth = width
        descriptor.outputHeight = height
        descriptor.colorTextureFormat = pixelFormat
        descriptor.depthTextureFormat = .r32Float
        descriptor.motionTextureFormat = .rg32Float
        descriptor.outputTextureFormat = pixelFormat

        guard let newInterpolator = descriptor.makeFrameInterpolator(device: device) else {
            print("SuperResVideoPlayer: failed to create MTLFXFrameInterpolator.")
            return false
        }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        depthDescriptor.usage = newInterpolator.depthTextureUsage
        depthDescriptor.storageMode = .private
        guard let newDepthTexture = device.makeTexture(descriptor: depthDescriptor) else { return false }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        outputDescriptor.usage = newInterpolator.outputTextureUsage
        outputDescriptor.storageMode = .private
        guard let newOutputTexture = device.makeTexture(descriptor: outputDescriptor) else { return false }

        // Fill the depth texture once with a flat/constant value (see the
        // class doc comment on why video has no real depth to provide).
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(clearDepthPipeline)
            encoder.setTexture(newDepthTexture, index: 0)
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(
                width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        interpolator = newInterpolator
        depthTexture = newDepthTexture
        outputTexture = newOutputTexture
        configuredWidth = width
        configuredHeight = height
        return true
    }
}
