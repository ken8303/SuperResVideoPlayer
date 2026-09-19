import AVFoundation
import Metal
import MetalFX
import Vision
import CoreVideo

enum VideoExportError: LocalizedError {
    case cancelled
    case unreadableSource(String)
    case writerSetupFailed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Export was cancelled."
        case .unreadableSource(let why):
            return "Couldn't read the source video: \(why)"
        case .writerSetupFailed(let why):
            return "Couldn't create the output file: \(why)"
        case .processingFailed(let why):
            return "Export failed: \(why)"
        }
    }
}

/// Offline export: decodes the source video and re-applies the same
/// enhancement pipeline the player runs in real time — MetalFX Super
/// Resolution and/or AI frame interpolation — then encodes HEVC .mp4 with
/// the audio passed through.
///
/// Architecture note: the writer drives everything. AVAssetWriter's
/// `requestMediaDataWhenReady` callback is the only reliable way to feed a
/// non-realtime writer (polling `isReadyForMoreMediaData` wedges once the
/// encoder applies backpressure). Decode → enhance → append all happen
/// inside the provider callback, with at most one frame-pair of staged
/// output at a time.
final class VideoExporter {

    struct Configuration {
        var superResolutionEnabled: Bool
        var upscaleFactor: Double
        var frameInterpolationMultiplier: Int
        var imageEnhancementEnabled: Bool
        var enhancementEngine: EnhancerEngine
        var enhancementStrength: Double
        /// If set, stop after this many seconds of source video — used by
        /// the "test export" to compare engines without a full render.
        var durationLimitSeconds: Double?
    }

    private let workQueue = DispatchQueue(label: "SuperResVideoPlayer.VideoExport", qos: .userInitiated)
    private let providerQueue = DispatchQueue(label: "SuperResVideoPlayer.VideoExport.Provider", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "SuperResVideoPlayer.VideoExport.Audio", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var isCancelled = false

    func cancel() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
    }

    private var cancelledNow: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return isCancelled
    }

    private func checkCancelled() throws {
        if cancelledNow { throw VideoExportError.cancelled }
    }

    func export(
        source: URL,
        to destination: URL,
        configuration: Configuration,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workQueue.async {
                do {
                    try self.checkCancelled()
                    guard source.resolvingSymlinksInPath().standardizedFileURL !=
                            destination.resolvingSymlinksInPath().standardizedFileURL else {
                        throw VideoExportError.writerSetupFailed("Choose a destination other than the source video.")
                    }
                    try ExportDestination.write(to: destination) { temporary in
                        try self.exportSync(source: source, destination: temporary,
                                            configuration: configuration, onProgress: onProgress)
                        try self.checkCancelled()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Core (runs on workQueue; frame work runs on providerQueue)

    private func exportSync(
        source: URL,
        destination: URL,
        configuration: Configuration,
        onProgress: @escaping @MainActor (Double) -> Void
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw VideoExportError.processingFailed("No Metal-capable GPU available.")
        }

        let library = Renderer.loadShaderLibrary(device: device)
        guard let clearFn = library.makeFunction(name: "clearDepthKernel"),
              let warpFn = library.makeFunction(name: "warpBlendKernel"),
              let clearPipeline = try? device.makeComputePipelineState(function: clearFn),
              let warpPipeline = try? device.makeComputePipelineState(function: warpFn),
              let enhancer = EnhancementProcessor(device: device, library: library) else {
            throw VideoExportError.processingFailed("Couldn't build the compute pipelines.")
        }

        var cvCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cvCache)
        guard let textureCache = cvCache else {
            throw VideoExportError.processingFailed("Couldn't create a texture cache.")
        }

        // MARK: Reader

        let asset = AVURLAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw VideoExportError.unreadableSource("No video track found.")
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let fullDuration = asset.duration.seconds
        // Progress is measured against the (possibly capped) export length.
        let duration = min(fullDuration, configuration.durationLimitSeconds ?? fullDuration)
        let sourceFPS = Double(videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30)

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw VideoExportError.unreadableSource("Couldn't create a decoder for this file.")
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw VideoExportError.unreadableSource("Video track rejected by the decoder.")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil) // compressed passthrough
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        guard reader.startReading() else {
            throw VideoExportError.unreadableSource(reader.error?.localizedDescription ?? "Decoding failed to start.")
        }

        // MARK: First frame → writer setup

        guard let firstSample = videoOutput.copyNextSampleBuffer(),
              let firstBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw VideoExportError.unreadableSource(reader.error?.localizedDescription ?? "No video frames were decoded.")
        }
        let inputWidth = CVPixelBufferGetWidth(firstBuffer)
        let inputHeight = CVPixelBufferGetHeight(firstBuffer)
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(firstSample)

        // Enhancement state.
        let multiplier = max(1, configuration.frameInterpolationMultiplier)
        let frameInterpolator = FrameInterpolator(device: device)
        var metalFXUsable = (multiplier == 2)
        var spatialScaler: MTLFXSpatialScaler?
        var scalerOutput: MTLTexture?
        var warpOutput: MTLTexture?

        // "Max" engine (Real-ESRGAN via Core ML), export-only. Fails fast
        // here — before any decoding — if the model isn't installed.
        var maxEnhancer: NeuralEnhancer?
        if configuration.imageEnhancementEnabled,
           configuration.enhancementStrength > 0,
           configuration.enhancementEngine == .max {
            maxEnhancer = try NeuralEnhancer(device: device)
        }

        var outWidth = inputWidth
        var outHeight = inputHeight
        if configuration.superResolutionEnabled {
            let wantWidth = max(inputWidth, Int(Double(inputWidth) * configuration.upscaleFactor))
            let wantHeight = max(inputHeight, Int(Double(inputHeight) * configuration.upscaleFactor))
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = inputWidth
            descriptor.inputHeight = inputHeight
            descriptor.outputWidth = wantWidth
            descriptor.outputHeight = wantHeight
            descriptor.colorTextureFormat = .bgra8Unorm
            descriptor.outputTextureFormat = .bgra8Unorm
            descriptor.colorProcessingMode = .perceptual
            if MTLFXSpatialScalerDescriptor.supportsDevice(device),
               let scaler = descriptor.makeSpatialScaler(device: device) {
                let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: wantWidth, height: wantHeight, mipmapped: false)
                outDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                outDescriptor.storageMode = .private
                if let outTexture = device.makeTexture(descriptor: outDescriptor) {
                    spatialScaler = scaler
                    scalerOutput = outTexture
                    outWidth = wantWidth
                    outHeight = wantHeight
                }
            }
        }

        // MARK: Writer

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let outputFPS = sourceFPS * Double(multiplier)
        let bitrate = min(80_000_000, max(2_000_000, Int(Double(outWidth * outHeight) * outputFPS * 0.07)))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(outputFPS.rounded())
            ]
        ])
        var outputTransform = videoTrack.preferredTransform
        let rotatedBounds = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
            .applying(outputTransform)
        outputTransform.tx -= rotatedBounds.minX
        outputTransform.ty -= rotatedBounds.minY
        videoInput.transform = outputTransform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw VideoExportError.writerSetupFailed("Video settings rejected.")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outWidth,
                kCVPixelBufferHeightKey as String: outHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )

        var audioInput: AVAssetWriterInput?
        if let audioTrack, audioOutput != nil {
            var formatHint: CMFormatDescription?
            if let first = audioTrack.formatDescriptions.first {
                formatHint = (first as! CMFormatDescription)
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatHint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw VideoExportError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed.")
        }
        writer.startSession(atSourceTime: firstPTS)

        // MARK: Frame helpers (called on providerQueue)

        // Used only by the serial video provider. GPU work completes before
        // each stage releases these Core Video texture wrappers.
        var frameTextureBackings: [CVMetalTexture] = []
        func wrapTexture(_ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> MTLTexture? {
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil, format,
                CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture
            )
            guard status == kCVReturnSuccess, let cvTexture else { return nil }
            frameTextureBackings.append(cvTexture)
            return CVMetalTextureGetTexture(cvTexture)
        }

        func enhanceIfNeeded(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
            guard configuration.imageEnhancementEnabled, configuration.enhancementStrength > 0 else {
                return texture
            }
            if let maxEnhancer {
                // Real-ESRGAN runs synchronously on its own queue; its
                // output then flows into this command buffer's SR pass.
                let enhanced = try maxEnhancer.enhance(texture) { try self.checkCancelled() }
                guard let blended = enhancer.blend(original: texture, enhanced: enhanced,
                                                    strength: configuration.enhancementStrength,
                                                    commandBuffer: commandBuffer) else {
                    throw VideoExportError.processingFailed("Couldn't apply the Max engine strength.")
                }
                return blended
            }
            return enhancer.process(texture,
                                    neural: configuration.enhancementEngine == .neural,
                                    strength: configuration.enhancementStrength,
                                    commandBuffer: commandBuffer) ?? texture
        }

        func upscaleIfNeeded(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture {
            guard let scaler = spatialScaler, let output = scalerOutput else { return texture }
            scaler.colorTexture = texture
            scaler.outputTexture = output
            scaler.encode(commandBuffer: commandBuffer)
            return output
        }

        func warpBlend(previous: MTLTexture, current: MTLTexture, motion: MTLTexture,
                       t: Double, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
            if warpOutput == nil || warpOutput?.width != current.width || warpOutput?.height != current.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: current.width, height: current.height, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                warpOutput = device.makeTexture(descriptor: descriptor)
            }
            guard let output = warpOutput,
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(warpPipeline)
            encoder.setTexture(previous, index: 0)
            encoder.setTexture(current, index: 1)
            encoder.setTexture(motion, index: 2)
            encoder.setTexture(output, index: 3)
            var tValue = Float(t)
            encoder.setBytes(&tValue, length: MemoryLayout<Float>.size, index: 0)
            let group = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (current.width + 15) / 16, height: (current.height + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
            return output
        }

        func computeFlow(previous: CVPixelBuffer, current: CVPixelBuffer) -> (texture: MTLTexture, backing: CVPixelBuffer)? {
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: current, options: [:])
            request.computationAccuracy = .medium
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first else { return nil }
            let flowBuffer = observation.pixelBuffer
            guard let texture = wrapTexture(flowBuffer, format: .rg32Float) else { return nil }
            return (texture, flowBuffer)
        }

        /// Renders `texture` into a fresh output pixel buffer (blocking on
        /// the GPU) — the writer-side half of producing one output frame.
        func renderToOutputBuffer(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> CVPixelBuffer {
            guard let pool = adaptor.pixelBufferPool else {
                throw VideoExportError.writerSetupFailed("Pixel buffer pool unavailable.")
            }
            var newBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &newBuffer)
            guard let outBuffer = newBuffer,
                  let outTexture = wrapTexture(outBuffer, format: .bgra8Unorm),
                  let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw VideoExportError.processingFailed("Couldn't stage an output frame.")
            }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: outTexture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw VideoExportError.processingFailed(commandBuffer.error?.localizedDescription ?? "GPU processing failed.")
            }
            return outBuffer
        }

        // MARK: Provider state

        var previous: (buffer: CVPixelBuffer, texture: MTLTexture, backing: CVMetalTexture, pts: CMTime)?
        var staged: [(buffer: CVPixelBuffer, pts: CMTime)] = []
        var pendingFirstSample: CMSampleBuffer? = firstSample
        var realFrames = 0
        var synthFrames = 0
        var computeFlowFailures = 0
        var lastProgressPush = 0.0
        let exportStart = Date()

        var providerError: Error?
        var videoFinished = false
        let videoDone = DispatchSemaphore(value: 0)

        /// Processes one decoded sample into 1..multiplier staged output
        /// buffers (synthesized in-betweens first, then the real frame).
        func stageOutputs(for sample: CMSampleBuffer) throws {
            defer { frameTextureBackings.removeAll(keepingCapacity: true) }
            try checkCancelled()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let texture = wrapTexture(pixelBuffer, format: .bgra8Unorm),
                  let colorBacking = frameTextureBackings.last else {
                throw VideoExportError.processingFailed("Couldn't access the decoded video frame.")
            }

            if multiplier > 1, let prev = previous, pts > prev.pts {
                let flowResult = computeFlow(previous: prev.buffer, current: pixelBuffer)
                if flowResult == nil, computeFlowFailures < 3 {
                    computeFlowFailures += 1
                    print("SuperResVideoPlayer: export — optical flow failed at \(String(format: "%.2f", pts.seconds))s; passing frames through un-interpolated")
                }
                if let flow = flowResult {
                    let span = pts - prev.pts
                    for step in 1..<multiplier {
                        let t = Double(step) / Double(multiplier)
                        guard let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
                        var synthesized: MTLTexture?
                        if multiplier == 2, metalFXUsable {
                            synthesized = frameInterpolator.interpolate(
                                previous: prev.texture, current: texture,
                                motionTexture: flow.texture, deltaTime: span.seconds,
                                clearDepthPipeline: clearPipeline, commandBuffer: commandBuffer)
                            if synthesized == nil { metalFXUsable = frameInterpolator.isSupported }
                        }
                        if synthesized == nil {
                            synthesized = warpBlend(previous: prev.texture, current: texture,
                                                    motion: flow.texture, t: t, commandBuffer: commandBuffer)
                        }
                        guard let synthTexture = synthesized else {
                            commandBuffer.commit()
                            continue
                        }
                        var enhancementCommands = commandBuffer
                        if maxEnhancer != nil {
                            commandBuffer.commit()
                            commandBuffer.waitUntilCompleted()
                            guard commandBuffer.status == .completed,
                                  let next = commandQueue.makeCommandBuffer() else {
                                throw VideoExportError.processingFailed("Couldn't finish the interpolated frame for the Max engine.")
                            }
                            enhancementCommands = next
                        }
                        let finalTexture = upscaleIfNeeded(try enhanceIfNeeded(synthTexture, commandBuffer: enhancementCommands),
                                                           commandBuffer: enhancementCommands)
                        let outBuffer = try renderToOutputBuffer(finalTexture, commandBuffer: enhancementCommands)
                        staged.append((outBuffer, prev.pts + CMTimeMultiplyByFloat64(span, multiplier: t)))
                        synthFrames += 1
                    }
                    _ = flow.backing
                }
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            let finalTexture = upscaleIfNeeded(try enhanceIfNeeded(texture, commandBuffer: commandBuffer),
                                               commandBuffer: commandBuffer)
            let outBuffer = try renderToOutputBuffer(finalTexture, commandBuffer: commandBuffer)
            staged.append((outBuffer, pts))

            previous = (pixelBuffer, texture, colorBacking, pts)
            realFrames += 1

            // Without this flush the texture cache pins the decoder's
            // pixel-buffer pool and decoding stalls after a few dozen frames.
            CVMetalTextureCacheFlush(textureCache, 0)

            if realFrames % 120 == 0 {
                let elapsed = Date().timeIntervalSince(exportStart)
                let rate = Double(realFrames + synthFrames) / max(elapsed, 0.001)
                print(String(format: "SuperResVideoPlayer: export — %d real + %d synth frames, %.1f fps, video time %.1fs / %.1fs",
                             realFrames, synthFrames, rate, pts.seconds, duration))
            }
            if duration > 0 {
                let progress = min(1.0, max(0.0, pts.seconds / duration))
                if progress - lastProgressPush >= 0.0005 {
                    lastProgressPush = progress
                    Task { @MainActor in onProgress(progress) }
                }
            }
        }

        // MARK: Writer-driven video loop

        videoInput.requestMediaDataWhenReady(on: providerQueue) {
            guard !videoFinished else { return }
            do {
                while videoInput.isReadyForMoreMediaData {
                    if self.cancelledNow { throw VideoExportError.cancelled }

                    if let next = staged.first {
                        if !adaptor.append(next.buffer, withPresentationTime: next.pts) {
                            throw VideoExportError.processingFailed(writer.error?.localizedDescription ?? "Frame append failed.")
                        }
                        staged.removeFirst()
                        continue
                    }

                    let sample: CMSampleBuffer?
                    if let first = pendingFirstSample {
                        sample = first
                        pendingFirstSample = nil
                    } else {
                        sample = videoOutput.copyNextSampleBuffer()
                    }
                    // Test export: stop once we've passed the time cap.
                    if let sample, let limit = configuration.durationLimitSeconds,
                       CMSampleBufferGetPresentationTimeStamp(sample).seconds > limit {
                        videoFinished = true
                        videoInput.markAsFinished()
                        videoDone.signal()
                        return
                    }
                    guard let sample else {
                        videoFinished = true
                        videoInput.markAsFinished()
                        videoDone.signal()
                        return
                    }
                    try autoreleasepool { try stageOutputs(for: sample) }
                }
            } catch {
                providerError = error
                videoFinished = true
                videoInput.markAsFinished()
                videoDone.signal()
            }
        }

        // MARK: Audio passthrough — MUST run concurrently with video.
        // AVAssetWriter interleaves its tracks: it stops requesting video
        // once video runs ~2s ahead of audio, so feeding audio "afterwards"
        // deadlocks the video provider almost immediately.

        var audioError: Error?
        var audioFinished = false
        let audioDone = DispatchSemaphore(value: 0)
        if let audioOutput, let audioInput {
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                guard !audioFinished else { return }
                func finishAudio() {
                    audioFinished = true
                    audioInput.markAsFinished()
                    audioDone.signal()
                }
                while audioInput.isReadyForMoreMediaData {
                    if self.cancelledNow {
                        audioError = VideoExportError.cancelled
                        finishAudio()
                        return
                    }
                    let sample = audioOutput.copyNextSampleBuffer()
                    // Match the video time cap for test exports.
                    if let sample, let limit = configuration.durationLimitSeconds,
                       CMSampleBufferGetPresentationTimeStamp(sample).seconds > limit {
                        finishAudio()
                        return
                    }
                    guard let sample else {
                        finishAudio()
                        return
                    }
                    if !audioInput.append(sample) {
                        audioError = VideoExportError.processingFailed(
                            writer.error?.localizedDescription ?? "Audio append failed.")
                        finishAudio()
                        return
                    }
                }
            }
        } else {
            audioDone.signal()
        }

        // Wait for both providers, staying responsive to cancellation
        // (cancelReading makes both copyNextSampleBuffer return nil, which
        // drains the providers cleanly).
        func waitForProvider(_ done: DispatchSemaphore) throws {
            while done.wait(timeout: .now() + 0.25) == .timedOut {
                // A failed writer stops calling providers. Cancelling only the
                // reader cannot wake callbacks waiting for writer readiness.
                if cancelledNow || writer.status == .failed || reader.status == .failed {
                    reader.cancelReading()
                    writer.cancelWriting()
                    providerQueue.sync { }
                    audioQueue.sync { }
                    try checkCancelled()
                    throw VideoExportError.processingFailed(
                        writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Export stopped unexpectedly.")
                }
            }
        }
        try waitForProvider(videoDone)
        try waitForProvider(audioDone)

        if let providerError {
            writer.cancelWriting()
            throw providerError
        }
        if let audioError {
            writer.cancelWriting()
            throw audioError
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoExportError.unreadableSource(reader.error?.localizedDescription ?? "Decoding failed midway.")
        }

        try checkCancelled()

        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSemaphore.signal() }
        while finishSemaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if cancelledNow {
                writer.cancelWriting()
                throw VideoExportError.cancelled
            }
        }
        guard writer.status == .completed else {
            throw VideoExportError.processingFailed(writer.error?.localizedDescription ?? "Finalizing failed.")
        }
        Task { @MainActor in onProgress(1.0) }
    }
}
