import CoreML
import Metal
import MetalPerformanceShaders
import CoreVideo

/// The "Max" image-enhancer engine: Real-ESRGAN (realesr-animevideov3)
/// running through Core ML on the Neural Engine/GPU. Used during export
/// only — it costs on the order of 100+ ms per 1080p frame, far too slow
/// for live playback.
///
/// The model is a fixed 512x512 → 2048x2048 (4x) network, so frames are
/// processed as overlapping 512px tiles: each tile is enhanced at 4x,
/// Lanczos-resampled straight back to tile size (so the *frame* resolution
/// never changes — the 4x pass exists purely to reconstruct detail), and
/// the tile interiors are stitched into the output, discarding the overlap
/// margins to hide seams.
///
/// The .mlpackage is produced once by `bash convert-model.sh` and lives in
/// ~/Library/Application Support/SuperResVideoPlayer/.
final class NeuralEnhancer {

    static var modelPackageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperResVideoPlayer/RealESRGAN.mlpackage")
    }

    static var isModelAvailable: Bool {
        FileManager.default.fileExists(atPath: modelPackageURL.path)
    }

    private let tileSize = 512
    private let overlap = 16
    private let scale = 4

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let lanczos: MPSImageLanczosScale
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    private var textureCache: CVMetalTextureCache?
    private var tileInputBuffer: CVPixelBuffer?
    private var tileInputTexture: MTLTexture?
    private var tileInputBacking: CVMetalTexture?
    private var tileDownTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var lastFrameSize: (width: Int, height: Int) = (0, 0)

    init(device: MTLDevice) throws {
        guard Self.isModelAvailable else {
            throw VideoExportError.processingFailed(
                "The Max engine needs the Real-ESRGAN model — run `bash convert-model.sh` once, then retry.")
        }
        guard let queue = device.makeCommandQueue() else {
            throw VideoExportError.processingFailed("Couldn't create a Metal queue for the Max engine.")
        }
        self.device = device
        self.commandQueue = queue
        self.lanczos = MPSImageLanczosScale(device: device)

        // Compile (fast for this ~2 MB model) and load, preferring the ANE.
        let compiled = try MLModel.compileModel(at: Self.modelPackageURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: compiled, configuration: configuration)

        guard let input = model.modelDescription.inputDescriptionsByName.keys.first,
              let output = model.modelDescription.outputDescriptionsByName.keys.first else {
            throw VideoExportError.processingFailed("The Real-ESRGAN model has an unexpected interface.")
        }
        self.inputName = input
        self.outputName = output

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        // Fixed-size tile staging resources.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: tileSize,
            kCVPixelBufferHeightKey as String: tileSize,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, tileSize, tileSize,
                            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer, let cache = textureCache,
              let inputTexture = Self.wrap(buffer, format: .bgra8Unorm, cache: cache) else {
            throw VideoExportError.processingFailed("Couldn't allocate tile buffers for the Max engine.")
        }
        tileInputBuffer = buffer
        tileInputTexture = inputTexture.texture
        tileInputBacking = inputTexture.backing
        // Small frames do not fill a 512px tile. Define the padding rather
        // than feeding uninitialized memory into the model.
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * tileSize)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let downDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: tileSize, height: tileSize, mipmapped: false)
        downDescriptor.usage = [.shaderRead, .shaderWrite]
        tileDownTexture = device.makeTexture(descriptor: downDescriptor)
    }

    /// Enhances `input` at its own resolution (synchronous; export-only).
    func enhance(_ input: MTLTexture, checkCancellation: () throws -> Void = {}) throws -> MTLTexture {
        let width = input.width
        let height = input.height

        if outputTexture == nil || lastFrameSize != (width, height) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            outputTexture = device.makeTexture(descriptor: descriptor)
            lastFrameSize = (width, height)
        }
        guard let output = outputTexture,
              let tileInputBuffer, let tileInputTexture, let tileDownTexture,
              let cache = textureCache else {
            throw VideoExportError.processingFailed("Max engine buffers unavailable.")
        }

        let core = tileSize - 2 * overlap
        var tileY = 0
        while tileY < height {
            var tileX = 0
            while tileX < width {
                try checkCancellation()
                // Source window: 512px, shifted so it stays inside the frame.
                let srcX = max(0, min(tileX - overlap, width - tileSize))
                let srcY = max(0, min(tileY - overlap, height - tileSize))
                let copyWidth = min(tileSize, width)
                let copyHeight = min(tileSize, height)

                // 1. Stage the tile.
                guard let stageBuffer = commandQueue.makeCommandBuffer(),
                      let stageBlit = stageBuffer.makeBlitCommandEncoder() else {
                    throw VideoExportError.processingFailed("Max engine: blit failed.")
                }
                stageBlit.copy(from: input, sourceSlice: 0, sourceLevel: 0,
                               sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                               sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                               to: tileInputTexture, destinationSlice: 0, destinationLevel: 0,
                               destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                stageBlit.endEncoding()
                stageBuffer.commit()
                stageBuffer.waitUntilCompleted()
                guard stageBuffer.status == .completed else {
                    throw VideoExportError.processingFailed(stageBuffer.error?.localizedDescription ?? "Max engine: tile upload failed.")
                }

                // 2. Inference.
                let features = try MLDictionaryFeatureProvider(
                    dictionary: [inputName: MLFeatureValue(pixelBuffer: tileInputBuffer)])
                let prediction = try model.prediction(from: features)
                guard let enhancedBuffer = prediction.featureValue(for: outputName)?.imageBufferValue,
                      let enhancedTexture = Self.wrap(enhancedBuffer, format: .bgra8Unorm, cache: cache) else {
                    throw VideoExportError.processingFailed("Max engine: model returned no image.")
                }

                // 3. Resample the 4x tile straight back to tile size, then
                //    stitch the interior into the output.
                guard let finishBuffer = commandQueue.makeCommandBuffer() else {
                    throw VideoExportError.processingFailed("Max engine: command buffer failed.")
                }
                lanczos.encode(commandBuffer: finishBuffer,
                               sourceTexture: enhancedTexture.texture,
                               destinationTexture: tileDownTexture)
                guard let stitch = finishBuffer.makeBlitCommandEncoder() else {
                    throw VideoExportError.processingFailed("Max engine: tile stitching failed.")
                }
                do {
                    let innerX = tileX - srcX
                    let innerY = tileY - srcY
                    let stitchWidth = min(core, width - tileX)
                    let stitchHeight = min(core, height - tileY)
                    stitch.copy(from: tileDownTexture, sourceSlice: 0, sourceLevel: 0,
                                sourceOrigin: MTLOrigin(x: innerX, y: innerY, z: 0),
                                sourceSize: MTLSize(width: stitchWidth, height: stitchHeight, depth: 1),
                                to: output, destinationSlice: 0, destinationLevel: 0,
                                destinationOrigin: MTLOrigin(x: tileX, y: tileY, z: 0))
                    stitch.endEncoding()
                }
                finishBuffer.commit()
                finishBuffer.waitUntilCompleted()
                withExtendedLifetime((enhancedBuffer, enhancedTexture.backing)) { }
                guard finishBuffer.status == .completed else {
                    throw VideoExportError.processingFailed(finishBuffer.error?.localizedDescription ?? "Max engine: tile processing failed.")
                }
                CVMetalTextureCacheFlush(cache, 0)

                tileX += core
            }
            tileY += core
        }

        return output
    }

    private static func wrap(_ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat,
                             cache: CVMetalTextureCache) -> (texture: MTLTexture, backing: CVMetalTexture)? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }
}
