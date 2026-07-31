import Metal
import MetalFX

/// The "AI Image Enhancer": cleans and sharpens a frame **without changing
/// its resolution**. Two engines:
///
///  - **Classic** — one compute pass: edge-aware denoise + contrast-adaptive
///    sharpening (`enhanceKernel` in Shaders.metal). Cheapest, predictable.
///  - **Neural** — MetalFX's ML-based spatial scaler reconstructs the image
///    at 2x, a Lanczos filter resamples it back to native size
///    (supersampling: reconstructed detail, cleaner edges, less aliasing),
///    then a lighter adaptive sharpen finishes. Costs a MetalFX pass per
///    frame; automatically falls back to Classic where MetalFX is
///    unsupported.
///
/// Shared by the realtime `Renderer` and the offline `VideoExporter`.
final class EnhancementProcessor {

    struct EnhanceParams {
        var sharpness: Float
        var denoise: Float
    }

    private let device: MTLDevice
    /// Pixel format of the textures flowing through this processor. Defaults
    /// to 8-bit for the export path; playback passes its 16-bit format.
    private let pixelFormat: MTLPixelFormat
    private let enhancePipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState

    private var casOutput: MTLTexture?
    private var neuralUpscaled: MTLTexture?
    private var neuralDownscaled: MTLTexture?
    private var neuralScaler: MTLFXSpatialScaler?
    private var lastSize: (width: Int, height: Int) = (0, 0)
    private(set) var neuralSupported = true

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let enhanceFn = library.makeFunction(name: "enhanceKernel"),
              let downsampleFn = library.makeFunction(name: "downsampleKernel"),
              let enhance = try? device.makeComputePipelineState(function: enhanceFn),
              let downsample = try? device.makeComputePipelineState(function: downsampleFn) else {
            return nil
        }
        self.device = device
        self.pixelFormat = pixelFormat
        self.enhancePipeline = enhance
        self.downsamplePipeline = downsample
    }

    /// Enhances `input` at its own resolution. Not thread-safe — call from
    /// a single thread per instance (each owner creates its own).
    func process(_ input: MTLTexture, neural: Bool, strength: Double,
                 commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        ensureResources(width: input.width, height: input.height, wantNeural: neural)

        if neural, neuralSupported,
           let scaler = neuralScaler,
           let upscaled = neuralUpscaled,
           let downscaled = neuralDownscaled {
            scaler.colorTexture = input
            scaler.outputTexture = upscaled
            scaler.encode(commandBuffer: commandBuffer)
            guard downsample(from: upscaled, to: downscaled, commandBuffer: commandBuffer) else {
                return applyCAS(to: input, sharpness: Float(strength),
                                denoise: Float(strength * 0.7), commandBuffer: commandBuffer)
            }
            // The supersample already denoised/reconstructed — finish with
            // a lighter sharpen only.
            return applyCAS(to: downscaled,
                            sharpness: Float(strength * 0.6),
                            denoise: 0,
                            commandBuffer: commandBuffer)
        }

        return applyCAS(to: input,
                        sharpness: Float(strength),
                        denoise: Float(strength * 0.7),
                        commandBuffer: commandBuffer)
    }

    // MARK: Internals

    private func ensureResources(width: Int, height: Int, wantNeural: Bool) {
        if lastSize != (width, height) {
            lastSize = (width, height)
            casOutput = makeTexture(width: width, height: height, renderTarget: false)
            neuralScaler = nil
            neuralUpscaled = nil
            neuralDownscaled = nil
        }

        if wantNeural, neuralSupported, neuralScaler == nil {
            // The neural path reconstructs at 2x internally; that intermediate
            // texture must stay within the GPU's 16384-per-side limit. For
            // frames wider/taller than 8192 (e.g. 8K VR), fall back to the
            // Classic engine rather than failing.
            guard width * 2 <= 16384, height * 2 <= 16384,
                  MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
                neuralSupported = false
                return
            }
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = width
            descriptor.inputHeight = height
            descriptor.outputWidth = width * 2
            descriptor.outputHeight = height * 2
            descriptor.colorTextureFormat = pixelFormat
            descriptor.outputTextureFormat = pixelFormat
            descriptor.colorProcessingMode = .perceptual
            guard let scaler = descriptor.makeSpatialScaler(device: device),
                  let upscaled = makeTexture(width: width * 2, height: height * 2, renderTarget: true),
                  let downscaled = makeTexture(width: width, height: height, renderTarget: false) else {
                neuralSupported = false
                return
            }
            neuralScaler = scaler
            neuralUpscaled = upscaled
            neuralDownscaled = downscaled
        }
    }

    private func makeTexture(width: Int, height: Int, renderTarget: Bool) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = renderTarget ? [.shaderRead, .shaderWrite, .renderTarget]
                                        : [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func downsample(from src: MTLTexture, to dst: MTLTexture,
                            commandBuffer: MTLCommandBuffer) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(downsamplePipeline)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (dst.width + 15) / 16, height: (dst.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        return true
    }

    private func applyCAS(to input: MTLTexture, sharpness: Float, denoise: Float,
                          commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let output = casOutput,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(enhancePipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        var params = EnhanceParams(sharpness: sharpness, denoise: denoise)
        encoder.setBytes(&params, length: MemoryLayout<EnhanceParams>.size, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (input.width + 15) / 16,
                           height: (input.height + 15) / 16,
                           depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        return output
    }
}
