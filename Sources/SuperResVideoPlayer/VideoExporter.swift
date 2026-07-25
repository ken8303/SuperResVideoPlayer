import AVFoundation
import CoreMedia
import Metal
import MetalFX
import Vision
import CoreVideo
import SuperResCore

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
///
/// `@unchecked Sendable`: the only cross-thread mutable state (`isCancelled`)
/// is guarded by `cancelLock`; per-export state lives in `exportSync`'s
/// stack and is coordinated by locks/serial queues within a single call.
final class VideoExporter: @unchecked Sendable {

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
        /// Zero-based index among the source's audio tracks (container
        /// order, matching the app's Audio picker). Callers must pass 0 when
        /// the source has already been remuxed/transcoded down to a single
        /// audio track.
        var audioTrackIndex: Int = 0
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

    /// Asset metadata loaded via the async API (avoids the deprecated
    /// synchronous AVAsset accessors) and handed to the background worker.
    /// `@unchecked Sendable`: AVURLAsset/AVAssetTrack are immutable handles
    /// here, only read on the worker queue.
    private struct SourceInfo: @unchecked Sendable {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let durationSeconds: Double
        let sourceFPS: Double
        let audioChannels: Int
        let audioSampleRate: Double
    }

    func export(
        source: URL,
        to destination: URL,
        configuration: Configuration,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // Load everything we need from the asset up front with the async
        // API, so the synchronous background worker never touches the
        // deprecated AVAsset accessors.
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.unreadableSource("No video track found.")
        }
        // Honor the user's Audio picker selection; clamp defensively in case
        // AVFoundation exposes fewer tracks than mpv did (it can't read some
        // codecs), falling back to the first rather than exporting silence.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack: AVAssetTrack? = audioTracks.isEmpty
            ? nil
            : audioTracks[min(max(0, configuration.audioTrackIndex), audioTracks.count - 1)]
        let duration = try await asset.load(.duration).seconds
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)

        var audioChannels = 2
        var audioSampleRate = 48000.0
        if let audioTrack {
            let formats = try await audioTrack.load(.formatDescriptions)
            if let fmt = formats.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                if asbd.mChannelsPerFrame > 0 { audioChannels = min(Int(asbd.mChannelsPerFrame), 2) }
                if asbd.mSampleRate > 0 { audioSampleRate = asbd.mSampleRate }
            }
        }

        let info = SourceInfo(
            asset: asset,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            durationSeconds: duration,
            sourceFPS: Double(nominalFPS > 0 ? nominalFPS : 30),
            audioChannels: audioChannels,
            audioSampleRate: audioSampleRate
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workQueue.async {
                do {
                    try self.exportSync(info: info, destination: destination,
                                        configuration: configuration, onProgress: onProgress)
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Core (runs on workQueue; frame work runs on providerQueue)

    private func exportSync(
        info: SourceInfo,
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

        let asset = info.asset
        let videoTrack = info.videoTrack
        let audioTrack = info.audioTrack
        // Progress is measured against the (possibly capped) export length.
        let duration = min(info.durationSeconds, configuration.durationLimitSeconds ?? info.durationSeconds)
        let sourceFPS = info.sourceFPS

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

        // Decode audio to PCM (rather than compressed passthrough) so the
        // writer can always re-encode it to AAC — passthrough silently
        // drops MP4-incompatible codecs. If the source has an audio track
        // we cannot configure, fail loudly instead of exporting mute.
        var audioOutput: AVAssetReaderTrackOutput?
        let audioChannels = info.audioChannels
        let audioSampleRate = info.audioSampleRate
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            guard reader.canAdd(output) else {
                throw VideoExportError.unreadableSource("This file's audio track couldn't be decoded for export.")
            }
            reader.add(output)
            audioOutput = output
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

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let outputFPS = sourceFPS * Double(multiplier)
        let bitrate = VideoMath.recommendedBitrate(width: outWidth, height: outHeight, fps: outputFPS)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(outputFPS.rounded())
            ]
        ])
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
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            // A present-but-unconfigurable audio track is a hard failure —
            // never silently export mute.
            guard writer.canAdd(input) else {
                throw VideoExportError.writerSetupFailed("Couldn't set up AAC audio for this file.")
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw VideoExportError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed.")
        }
        // Normalize output timestamps to start at zero (sources can have a
        // non-zero starting PTS after edits/remuxing).
        let timeOffset = firstPTS
        writer.startSession(atSourceTime: .zero)

        // MARK: Frame helpers (called on providerQueue)

        func wrapTexture(_ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> MTLTexture? {
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil, format,
                CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture
            )
            guard status == kCVReturnSuccess, let cvTexture else { return nil }
            return CVMetalTextureGetTexture(cvTexture)
        }

        func enhanceIfNeeded(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
            guard configuration.imageEnhancementEnabled, configuration.enhancementStrength > 0 else {
                return texture
            }
            if let maxEnhancer {
                // Real-ESRGAN runs synchronously on its own queue; its
                // output then flows into this command buffer's SR pass.
                return try maxEnhancer.enhance(texture)
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
            return outBuffer
        }

        // MARK: Provider state

        var previous: (buffer: CVPixelBuffer, texture: MTLTexture, pts: CMTime)?
        var staged: [(buffer: CVPixelBuffer, pts: CMTime)] = []
        var pendingFirstSample: CMSampleBuffer? = firstSample
        var realFrames = 0
        var synthFrames = 0
        var computeFlowFailures = 0
        var lastProgressPush = 0.0
        let exportStart = Date()

        // Coordinated finish: any failure cancels the reader and unblocks
        // BOTH waits exactly once, so a failure on one track can't leave the
        // other provider backpressured (writer stops requesting it) and its
        // semaphore forever unsignalled.
        let finishLock = NSLock()
        var providerError: Error?
        var videoFinished = false
        var videoSignaled = false
        var audioSignaled = false
        let videoDone = DispatchSemaphore(value: 0)
        let audioDone = DispatchSemaphore(value: 0)

        func signalVideoOnce() {
            finishLock.lock(); defer { finishLock.unlock() }
            if !videoSignaled { videoSignaled = true; videoDone.signal() }
        }
        func signalAudioOnce() {
            finishLock.lock(); defer { finishLock.unlock() }
            if !audioSignaled { audioSignaled = true; audioDone.signal() }
        }
        func fail(_ error: Error) {
            finishLock.lock()
            if providerError == nil { providerError = error }
            videoFinished = true
            finishLock.unlock()
            reader.cancelReading()   // makes both providers' copyNextSampleBuffer return nil
            signalVideoOnce()
            signalAudioOnce()
        }

        /// Processes one decoded sample into 1..multiplier staged output
        /// buffers (synthesized in-betweens first, then the real frame).
        func stageOutputs(for sample: CMSampleBuffer) throws {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let texture = wrapTexture(pixelBuffer, format: .bgra8Unorm) else { return }

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
                        let finalTexture = upscaleIfNeeded(try enhanceIfNeeded(synthTexture, commandBuffer: commandBuffer),
                                                           commandBuffer: commandBuffer)
                        let outBuffer = try renderToOutputBuffer(finalTexture, commandBuffer: commandBuffer)
                        let synthPTS = CMTimeSubtract(prev.pts + CMTimeMultiplyByFloat64(span, multiplier: t), timeOffset)
                        staged.append((outBuffer, synthPTS))
                        synthFrames += 1
                    }
                    _ = flow.backing
                }
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            let finalTexture = upscaleIfNeeded(try enhanceIfNeeded(texture, commandBuffer: commandBuffer),
                                               commandBuffer: commandBuffer)
            let outBuffer = try renderToOutputBuffer(finalTexture, commandBuffer: commandBuffer)
            staged.append((outBuffer, CMTimeSubtract(pts, timeOffset)))

            previous = (pixelBuffer, texture, pts)
            realFrames += 1

            // Without this flush the texture cache pins the decoder's
            // pixel-buffer pool and decoding stalls after a few dozen frames.
            CVMetalTextureCacheFlush(textureCache, 0)

            let elapsedVideo = CMTimeSubtract(pts, timeOffset).seconds
            if realFrames % 120 == 0 {
                let elapsed = Date().timeIntervalSince(exportStart)
                let rate = Double(realFrames + synthFrames) / max(elapsed, 0.001)
                print(String(format: "SuperResVideoPlayer: export — %d real + %d synth frames, %.1f fps, video time %.1fs / %.1fs",
                             realFrames, synthFrames, rate, elapsedVideo, duration))
            }
            if duration > 0 {
                let progress = min(1.0, max(0.0, elapsedVideo / duration))
                if progress - lastProgressPush >= 0.0005 {
                    lastProgressPush = progress
                    Task { @MainActor in onProgress(progress) }
                }
            }
        }

        // MARK: Writer-driven video loop

        videoInput.requestMediaDataWhenReady(on: providerQueue) {
            finishLock.lock(); let done = videoFinished; finishLock.unlock()
            guard !done else { return }
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
                    // Test export: stop once past the cap (timestamps
                    // normalized against the first video PTS).
                    if let sample, let limit = configuration.durationLimitSeconds,
                       CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), timeOffset).seconds > limit {
                        finishLock.lock(); videoFinished = true; finishLock.unlock()
                        videoInput.markAsFinished()
                        signalVideoOnce()
                        return
                    }
                    guard let sample else {
                        finishLock.lock(); videoFinished = true; finishLock.unlock()
                        videoInput.markAsFinished()
                        signalVideoOnce()
                        return
                    }
                    try stageOutputs(for: sample)
                }
            } catch {
                videoInput.markAsFinished()
                fail(error)
            }
        }

        // MARK: Audio (AAC) — MUST run concurrently with video.
        // AVAssetWriter interleaves its tracks: it stops requesting video
        // once video runs ~2s ahead of audio, so feeding audio "afterwards"
        // deadlocks the video provider almost immediately.

        if let audioOutput, let audioInput {
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    if self.cancelledNow {
                        audioInput.markAsFinished()
                        fail(VideoExportError.cancelled)
                        return
                    }
                    let sample = audioOutput.copyNextSampleBuffer()
                    if let sample, let limit = configuration.durationLimitSeconds,
                       CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), timeOffset).seconds > limit {
                        audioInput.markAsFinished()
                        signalAudioOnce()
                        return
                    }
                    guard let sample else {
                        audioInput.markAsFinished()
                        signalAudioOnce()
                        return
                    }
                    // Shift audio to the same zero-based timeline as video.
                    let adjusted = Self.offsetSampleTimestamps(sample, by: timeOffset) ?? sample
                    if !audioInput.append(adjusted) {
                        audioInput.markAsFinished()
                        fail(VideoExportError.processingFailed(
                            writer.error?.localizedDescription ?? "Audio append failed."))
                        return
                    }
                }
            }
        } else {
            signalAudioOnce()
        }

        // Wait for both providers. `fail()` unblocks both exactly once, and
        // a writer failure also breaks the loops.
        while videoDone.wait(timeout: .now() + 0.25) == .timedOut {
            if cancelledNow { reader.cancelReading() }
            if writer.status == .failed { fail(writer.error ?? VideoExportError.processingFailed("Writer failed.")) }
        }
        while audioDone.wait(timeout: .now() + 0.25) == .timedOut {
            if cancelledNow { reader.cancelReading() }
            if writer.status == .failed { fail(writer.error ?? VideoExportError.processingFailed("Writer failed.")) }
        }

        if let providerError {
            writer.cancelWriting()
            throw providerError
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoExportError.unreadableSource(reader.error?.localizedDescription ?? "Decoding failed midway.")
        }

        try checkCancelled()

        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSemaphore.signal() }
        finishSemaphore.wait()
        guard writer.status == .completed else {
            throw VideoExportError.processingFailed(writer.error?.localizedDescription ?? "Finalizing failed.")
        }
        Task { @MainActor in onProgress(1.0) }
    }

    /// Returns a copy of `sample` with its presentation (and decode)
    /// timestamps shifted earlier by `offset`, so audio lands on the same
    /// zero-based timeline as the normalized video.
    private static func offsetSampleTimestamps(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr else {
            return nil
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for i in 0..<timings.count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sample,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &adjusted) == noErr else {
            return nil
        }
        return adjusted
    }
}
