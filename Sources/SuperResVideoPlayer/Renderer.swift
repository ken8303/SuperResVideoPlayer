import Metal
import MetalKit
import MetalFX
import CoreVideo
import QuartzCore

/// MTKView delegate that:
///  1. Pulls the current video frame from the libmpv engine (`MPVPlayer`)
///     as a CVPixelBuffer.
///  2. Wraps it as a zero-copy Metal texture via CVMetalTextureCache.
///  3. Optionally synthesizes an in-between frame ("AI Frame Interpolation")
///     from the previous/current real frames using MetalFX (2x) or a custom
///     motion-compensated warp (3x) — see FrameInterpolator.swift and the
///     warpBlendKernel in Shaders.metal.
///  4. Optionally runs the result through a MetalFX spatial scaler ("Super
///     Resolution").
///  5. Draws the final texture to the drawable with a full-screen textured
///     triangle.
final class Renderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState!
    private var clearDepthPipelineState: MTLComputePipelineState!
    private var warpBlendPipelineState: MTLComputePipelineState!
    private var textureCache: CVMetalTextureCache!

    // MARK: AI Image Enhancer (shared implementation with VideoExporter)
    private var enhancementProcessor: EnhancementProcessor?

    private weak var playerViewModel: PlayerViewModel?

    // MARK: Thread-safe snapshot of UI state
    //
    // `draw(in:)` runs on MTKView's render thread, but PlayerViewModel's
    // `@Published` properties are written on main and aren't safe to read
    // off-main. `MetalVideoView.updateNSView` (main thread) pushes a
    // snapshot via `sync(with:)`; the render thread only ever reads the
    // lock-guarded copy.
    struct RenderSettings {
        var superResolutionEnabled = true
        var upscaleFactor: Double = 1.5
        var frameInterpolationMultiplier = 1
        var imageEnhancementEnabled = false
        var enhancementUsesNeural = false
        var enhancementStrength: Double = 0.5
        var frameSource: MPVPlayer?
    }
    private let settingsLock = NSLock()
    private var _settings = RenderSettings()

    /// Call from the main thread whenever the view model's state may have
    /// changed (SwiftUI's updateNSView is the natural hook).
    func sync(with viewModel: PlayerViewModel) {
        let snapshot = RenderSettings(
            superResolutionEnabled: viewModel.superResolutionEnabled,
            upscaleFactor: viewModel.upscaleFactor,
            frameInterpolationMultiplier: viewModel.frameInterpolationMultiplier,
            imageEnhancementEnabled: viewModel.imageEnhancementEnabled,
            // .max is export-only (Core ML, ~100ms+/frame); playback
            // previews it with the MetalFX neural path.
            enhancementUsesNeural: viewModel.enhancementEngine != .classic,
            enhancementStrength: viewModel.enhancementStrength,
            frameSource: viewModel.mpv
        )
        settingsLock.lock()
        _settings = snapshot
        settingsLock.unlock()
    }

    private var settings: RenderSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return _settings
    }

    // MARK: Super Resolution (MetalFX spatial scaler) state
    private var spatialScaler: MTLFXSpatialScaler?
    private var scaledOutputTexture: MTLTexture?
    private var lastScalerInputSize: (width: Int, height: Int) = (0, 0)
    private var lastUpscaleFactor: Double = 0
    private var metalFXUpscaleSupported: Bool = true

    // MARK: Frame Interpolation state
    private lazy var opticalFlow = OpticalFlowEstimator(device: device)
    private lazy var frameInterpolator = FrameInterpolator(device: device)
    private var warpOutputTexture: MTLTexture?
    private var lastWarpSize: (width: Int, height: Int) = (0, 0)
    private var metalFXInterpolationUsable = true

    /// The last two *real* decoded frames, kept alive together with their
    /// CVPixelBuffers (needed by Vision) and their playback timestamps
    /// (needed to compute how far playback has progressed between them).
    private struct FrameSample {
        let pixelBuffer: CVPixelBuffer
        let texture: MTLTexture
        let cvTexture: CVMetalTexture
        let itemTimeSeconds: Double
    }
    private var previousSample: FrameSample?
    private var currentSample: FrameSample?
    private var lastFrameSerial: UInt64 = 0
    private var lastMediaGeneration: UInt64?
    private var loggedFirstFrame = false

    private struct ProcessingKey: Equatable {
        let serial: UInt64
        let superResolution: Bool
        let scale: Double
        let enhancement: Bool
        let neural: Bool
        let strength: Double
    }
    private var processedFrame: (key: ProcessingKey, texture: MTLTexture)?

    /// Caches the last synthesized in-between frame, keyed on the source
    /// pair's timestamps and the temporal phase. At 120Hz refresh with
    /// 24–30fps video, the same (pair, t) is requested for many consecutive
    /// display refreshes — without this, the (expensive) MetalFX
    /// interpolator or warp kernel would re-encode identical work each time.
    private var cachedInterpolation: (previousTime: Double, currentTime: Double, t: Double, texture: MTLTexture, kind: FrameKind)?

    // MARK: Pipeline statistics (verifying SR/interpolation actually run)

    /// What kind of frame ended up on screen for a given draw.
    enum FrameKind {
        case real        // decoded frame shown as-is
        case metalFX     // synthesized by MTLFXFrameInterpolator
        case warp        // synthesized by the custom warp kernel
    }
    private var lastResolvedKind: FrameKind = .real
    private var statReal = 0
    private var statMetalFX = 0
    private var statWarp = 0
    private var lastStatsPushTime = CACurrentMediaTime()

    init(device: MTLDevice, playerViewModel: PlayerViewModel) {
        self.device = device
        self.playerViewModel = playerViewModel
        guard let queue = device.makeCommandQueue() else {
            fatalError("SuperResVideoPlayer: could not create a Metal command queue.")
        }
        self.commandQueue = queue
        super.init()

        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard cacheStatus == kCVReturnSuccess, textureCache != nil else {
            fatalError("SuperResVideoPlayer: could not create a CVMetalTextureCache (status \(cacheStatus)).")
        }
        buildPipelines()
        sync(with: playerViewModel) // initial snapshot (init runs on main)
    }

    /// Loads the shader library, handling both build systems:
    ///  - Xcode compiles the .metal resource into a default.metallib inside
    ///    the module bundle → `makeDefaultLibrary(bundle:)` finds it.
    ///  - Command-line `swift build` only *copies* Shaders.metal into the
    ///    resource bundle, so there's no metallib → read the source and
    ///    compile it at runtime with `makeLibrary(source:)`.
    /// Static so `VideoExporter` can reuse the same loader.
    static func loadShaderLibrary(device: MTLDevice) -> MTLLibrary {
        if let precompiled = try? device.makeDefaultLibrary(bundle: .module) {
            return precompiled
        }

        if let sourceURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal") {
            do {
                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                return try device.makeLibrary(source: source, options: nil)
            } catch {
                fatalError("SuperResVideoPlayer: failed to compile Shaders.metal at runtime: \(error)")
            }
        }

        if let fallback = device.makeDefaultLibrary() {
            return fallback
        }

        fatalError("SuperResVideoPlayer: could not load the Metal shader library from any source.")
    }

    private func buildPipelines() {
        let library = Self.loadShaderLibrary(device: device)

        guard let vertexFn = library.makeFunction(name: "videoVertexShader"),
              let fragmentFn = library.makeFunction(name: "videoFragmentShader") else {
            fatalError("SuperResVideoPlayer: missing shader functions in Shaders.metal.")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("SuperResVideoPlayer: failed to build render pipeline state: \(error)")
        }

        guard let clearDepthFn = library.makeFunction(name: "clearDepthKernel"),
              let warpBlendFn = library.makeFunction(name: "warpBlendKernel") else {
            fatalError("SuperResVideoPlayer: missing compute shader functions in Shaders.metal.")
        }

        do {
            clearDepthPipelineState = try device.makeComputePipelineState(function: clearDepthFn)
            warpBlendPipelineState = try device.makeComputePipelineState(function: warpBlendFn)
        } catch {
            fatalError("SuperResVideoPlayer: failed to build compute pipeline states: \(error)")
        }

        enhancementProcessor = EnhancementProcessor(device: device, library: library)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Scalers/warp textures are rebuilt lazily in draw(in:) based on the
        // current source frame size, not the drawable size.
    }

    func draw(in view: MTKView) {
        let settings = self.settings
        guard let source = settings.frameSource else { return }

        updateFrameHistory(source: source,
                           interpolationEnabled: settings.frameInterpolationMultiplier > 1)

        // Acquire presentation resources before encoding or caching GPU work.
        // Otherwise a missing drawable leaves cached textures uninitialized.
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let retainedPrevious = previousSample
        let retainedCurrent = currentSample
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime((retainedPrevious, retainedCurrent)) { }
        }
        commandBuffer.label = "SuperResVideoPlayer.frame"

        guard let frameTexture = resolveDisplayTexture(
            source: source,
            multiplier: max(1, settings.frameInterpolationMultiplier),
            commandBuffer: commandBuffer
        ) else {
            // No frame to show (startup, or a new file just loaded):
            // present a clear (black) frame so stale content doesn't linger.
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                return
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let processingKey = ProcessingKey(serial: lastFrameSerial,
                                          superResolution: settings.superResolutionEnabled,
                                          scale: settings.upscaleFactor,
                                          enhancement: settings.imageEnhancementEnabled,
                                          neural: settings.enhancementUsesNeural,
                                          strength: settings.enhancementStrength)
        let canCache = settings.frameInterpolationMultiplier == 1
        let cached = canCache && processedFrame?.key == processingKey ? processedFrame?.texture : nil
        var textureToDisplay: MTLTexture = cached ?? frameTexture

        // AI Image Enhancer: same-resolution denoise + adaptive sharpen,
        // applied before Super Resolution so the upscaler gets the cleaner
        // image.
        if cached == nil, settings.imageEnhancementEnabled, settings.enhancementStrength > 0 {
            if let enhanced = enhancementProcessor?.process(frameTexture,
                                                            neural: settings.enhancementUsesNeural,
                                                            strength: settings.enhancementStrength,
                                                            commandBuffer: commandBuffer) {
                textureToDisplay = enhanced
            }
        }

        if cached == nil, settings.superResolutionEnabled, metalFXUpscaleSupported {
            if let upscaled = upscale(textureToDisplay,
                                       factor: settings.upscaleFactor,
                                       commandBuffer: commandBuffer) {
                textureToDisplay = upscaled
            }
        }

        updateStats(input: frameTexture, output: textureToDisplay, settings: settings)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            cachedInterpolation = nil
            processedFrame = nil
            commandBuffer.commit()
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        // Preserve the video's aspect ratio when the window is resized.
        // The render pass clears the remaining area to black.
        let canvasWidth = Double(drawable.texture.width)
        let canvasHeight = Double(drawable.texture.height)
        let fit = min(canvasWidth / Double(textureToDisplay.width),
                      canvasHeight / Double(textureToDisplay.height))
        let videoWidth = Double(textureToDisplay.width) * fit
        let videoHeight = Double(textureToDisplay.height) * fit
        encoder.setViewport(MTLViewport(originX: (canvasWidth - videoWidth) / 2,
                                        originY: (canvasHeight - videoHeight) / 2,
                                        width: videoWidth, height: videoHeight,
                                        znear: 0, zfar: 1))
        encoder.setFragmentTexture(textureToDisplay, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        processedFrame = canCache ? (processingKey, textureToDisplay) : nil
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Frame history / pull from mpv

    private func updateFrameHistory(source: MPVPlayer, interpolationEnabled: Bool) {
        // mpv renders frames on its own dedicated queue; here we only pick
        // up the latest finished frame (never triggering mpv work from the
        // draw path — that caused menu-tracking deadlocks).
        guard let frame = source.latestFrame else {
            // Engine has no frame (a new file was just loaded) — drop our
            // history so the previous video's frames can't linger on screen.
            previousSample = nil
            currentSample = nil
            cachedInterpolation = nil
            processedFrame = nil
            opticalFlow.reset()
            return
        }
        guard frame.serial != lastFrameSerial,
              let wrapped = makeColorTexture(from: frame.pixelBuffer) else {
            return
        }
        if lastMediaGeneration != frame.generation {
            previousSample = nil
            currentSample = nil
            processedFrame = nil
            opticalFlow.reset()
            lastMediaGeneration = frame.generation
        }
        let texture = wrapped.texture
        cachedInterpolation = nil
        lastFrameSerial = frame.serial
        statReal += 1 // one count per *decoded* frame, not per display refresh

        if !loggedFirstFrame {
            loggedFirstFrame = true
            print("SuperResVideoPlayer: first video frame received (\(texture.width)x\(texture.height))")
        }

        let newSample = FrameSample(pixelBuffer: frame.pixelBuffer, texture: texture, cvTexture: wrapped.backing, itemTimeSeconds: frame.timeSeconds)

        // Ignore duplicate/backwards timestamps (can happen right after a seek).
        if let current = currentSample,
           newSample.itemTimeSeconds <= current.itemTimeSeconds ||
           newSample.itemTimeSeconds - current.itemTimeSeconds > 0.5 ||
           texture.width != current.texture.width || texture.height != current.texture.height {
            opticalFlow.reset()
            previousSample = nil
            currentSample = newSample
            return
        }

        previousSample = currentSample
        currentSample = newSample

        // Vision's optical flow is expensive (CPU/ANE); only run it when
        // Frame Interpolation is actually switched on, so leaving it "Off"
        // doesn't burn cycles for no visible benefit.
        if interpolationEnabled, let previous = previousSample, let current = currentSample {
            opticalFlow.requestFlow(
                previous: previous.pixelBuffer,
                current: current.pixelBuffer,
                previousTime: previous.itemTimeSeconds,
                currentTime: current.itemTimeSeconds
            )
        }
    }

    /// Decides which texture to actually display this frame: a real decoded
    /// frame, or a synthesized in-between frame, based on how far playback
    /// has progressed between `previousSample` and `currentSample` and the
    /// user's chosen interpolation multiplier.
    private func resolveDisplayTexture(source: MPVPlayer, multiplier: Int, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        lastResolvedKind = .real
        guard let current = currentSample else { return nil }
        guard multiplier > 1, let previous = previousSample, current.itemTimeSeconds > previous.itemTimeSeconds else {
            return current.texture
        }

        let itemTimeNow = source.playbackTime
        let span = current.itemTimeSeconds - previous.itemTimeSeconds
        let rawT = ((itemTimeNow - previous.itemTimeSeconds) / span).clamped(to: 0...1)
        let stepIndex = Int((rawT * Double(multiplier)).rounded())

        if stepIndex <= 0 { return previous.texture }
        if stepIndex >= multiplier { return current.texture }

        let t = Double(stepIndex) / Double(multiplier)

        guard let flow = opticalFlow.latestResult,
              approximatelyEqual(flow.previousTime, previous.itemTimeSeconds),
              approximatelyEqual(flow.currentTime, current.itemTimeSeconds) else {
            // No motion field for this exact pair yet (Vision is still
            // catching up asynchronously) — show the nearer real frame
            // rather than stalling or showing a wrong-pair blend.
            return t < 0.5 ? previous.texture : current.texture
        }

        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(flow) { }
        }

        // Already synthesized this exact (pair, t) on an earlier display
        // refresh? Reuse it instead of re-encoding identical GPU work.
        if let cached = cachedInterpolation,
           approximatelyEqual(cached.previousTime, previous.itemTimeSeconds),
           approximatelyEqual(cached.currentTime, current.itemTimeSeconds),
           abs(cached.t - t) < 0.0001 {
            lastResolvedKind = cached.kind
            return cached.texture
        }

        // Native MetalFX interpolator only produces a fixed midpoint frame,
        // so it's only usable for the 2x case (the sole intermediate step,
        // t == 0.5). Everything else uses the custom warp/blend kernel.
        if multiplier == 2, metalFXInterpolationUsable, abs(t - 0.5) < 0.001 {
            if let interpolated = frameInterpolator.interpolate(
                previous: previous.texture,
                current: current.texture,
                motionTexture: flow.motionTexture,
                deltaTime: current.itemTimeSeconds - previous.itemTimeSeconds,
                clearDepthPipeline: clearDepthPipelineState,
                commandBuffer: commandBuffer
            ) {
                cachedInterpolation = (previous.itemTimeSeconds, current.itemTimeSeconds, t, interpolated, .metalFX)
                lastResolvedKind = .metalFX
                statMetalFX += 1 // counted at synthesis, not per display refresh
                return interpolated
            }
            metalFXInterpolationUsable = frameInterpolator.isSupported
            reportSupportState()
        }

        if let warped = warpBlend(
            previous: previous.texture,
            current: current.texture,
            motionTexture: flow.motionTexture,
            t: t,
            commandBuffer: commandBuffer
        ) {
            cachedInterpolation = (previous.itemTimeSeconds, current.itemTimeSeconds, t, warped, .warp)
            lastResolvedKind = .warp
            statWarp += 1 // counted at synthesis, not per display refresh
            return warped
        }

        // Warp setup failed (e.g. texture allocation) — show the nearer
        // real frame rather than dropping the draw entirely.
        return t < 0.5 ? previous.texture : current.texture
    }

    // MARK: Custom warp/blend (3x fallback + non-MetalFX fallback)

    private func warpBlend(previous: MTLTexture, current: MTLTexture, motionTexture: MTLTexture, t: Double, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if warpOutputTexture == nil || lastWarpSize.width != current.width || lastWarpSize.height != current.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: current.width, height: current.height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            warpOutputTexture = texture
            lastWarpSize = (current.width, current.height)
        }

        guard let output = warpOutputTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(warpBlendPipelineState)
        encoder.setTexture(previous, index: 0)
        encoder.setTexture(current, index: 1)
        encoder.setTexture(motionTexture, index: 2)
        encoder.setTexture(output, index: 3)
        var tValue = Float(t)
        encoder.setBytes(&tValue, length: MemoryLayout<Float>.size, index: 0)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (current.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (current.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        return output
    }

    // MARK: Frame -> Metal texture

    private func makeColorTexture(from pixelBuffer: CVPixelBuffer) -> (texture: MTLTexture, backing: CVMetalTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (texture, cvTexture)
    }

    // MARK: MetalFX Super Resolution (unchanged from the initial version)

    private func upscale(_ input: MTLTexture, factor: Double, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let inputWidth = input.width
        let inputHeight = input.height
        let outputWidth = max(inputWidth, Int(Double(inputWidth) * factor))
        let outputHeight = max(inputHeight, Int(Double(inputHeight) * factor))

        let sizeChanged = lastScalerInputSize.width != inputWidth || lastScalerInputSize.height != inputHeight
        let factorChanged = lastUpscaleFactor != factor

        if spatialScaler == nil || sizeChanged || factorChanged {
            guard rebuildScaler(inputWidth: inputWidth, inputHeight: inputHeight,
                                 outputWidth: outputWidth, outputHeight: outputHeight) else {
                metalFXUpscaleSupported = false
                reportSupportState()
                return nil
            }
            lastScalerInputSize = (inputWidth, inputHeight)
            lastUpscaleFactor = factor
        }

        guard let scaler = spatialScaler, let output = scaledOutputTexture else {
            return nil
        }

        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)

        return output
    }

    private func rebuildScaler(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual

        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            print("SuperResVideoPlayer: MetalFX Spatial Scaler is not supported on this GPU. Falling back to native resolution.")
            return false
        }

        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            print("SuperResVideoPlayer: failed to create MTLFXSpatialScaler.")
            return false
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outputDescriptor.storageMode = .private

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            print("SuperResVideoPlayer: failed to allocate MetalFX output texture.")
            return false
        }

        spatialScaler = scaler
        scaledOutputTexture = outputTexture
        return true
    }

    /// Pushes a per-second summary of unique decoded/synthesized frames
    /// (counted where they're produced, so a paused video reads 0/0 and a
    /// 24fps source reads ~24 real — not once per display refresh) plus
    /// input→output resolution. This is the ground truth for "are SR and
    /// interpolation really on?".
    private func updateStats(input: MTLTexture, output: MTLTexture, settings: RenderSettings) {
        let now = CACurrentMediaTime()
        guard now - lastStatsPushTime >= 1.0 else { return }
        lastStatsPushTime = now

        let sr: String
        if !settings.superResolutionEnabled {
            sr = "off"
        } else if !metalFXUpscaleSupported {
            sr = "unsupported"
        } else if output.width > input.width {
            sr = String(format: "MetalFX %.1fx", settings.upscaleFactor)
        } else {
            sr = "on (no-op)"
        }

        let smoothing: String
        if settings.frameInterpolationMultiplier > 1 {
            let synth = statMetalFX + statWarp
            let engine = statMetalFX >= statWarp && statMetalFX > 0 ? "MetalFX"
                       : (statWarp > 0 ? "warp" : "waiting for motion data")
            smoothing = "\(settings.frameInterpolationMultiplier)x — \(statReal) real + \(synth) synth/s (\(engine))"
        } else {
            smoothing = "off"
        }

        let enhance: String
        if settings.imageEnhancementEnabled {
            let engine = settings.enhancementUsesNeural
                ? ((enhancementProcessor?.neuralSupported ?? false) ? "Neural" : "Classic*")
                : "Classic"
            enhance = String(format: "%@ %.0f%%", engine, settings.enhancementStrength * 100)
        } else {
            enhance = "off"
        }
        let text = "\(input.width)×\(input.height) → \(output.width)×\(output.height) · Enhance: \(enhance) · Super Res: \(sr) · Smoothing: \(smoothing)"
        statReal = 0
        statMetalFX = 0
        statWarp = 0

        DispatchQueue.main.async { [weak playerViewModel] in
            playerViewModel?.pipelineStatus = text
        }
    }

    // MARK: Surfacing GPU-support state to the UI

    /// Without this, toggling Super Resolution or Frame Interpolation on
    /// unsupported hardware just silently does nothing — the user has no
    /// way to tell "it's off" from "it's on but unsupported". Pushes the
    /// current support flags to `PlayerViewModel` so `ContentView` can show
    /// a note. `draw(in:)` runs on MTKView's own render thread, not
    /// necessarily main, so this hops to main before touching the
    /// `@Published` properties.
    private func reportSupportState() {
        let upscaleSupported = metalFXUpscaleSupported
        let interpolationSupported = metalFXInterpolationUsable
        DispatchQueue.main.async { [weak playerViewModel] in
            playerViewModel?.superResolutionUnsupported = !upscaleSupported
            playerViewModel?.nativeFrameInterpolationUnsupported = !interpolationSupported
        }
    }
}

private func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 0.0005) -> Bool {
    abs(a - b) <= tolerance
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
