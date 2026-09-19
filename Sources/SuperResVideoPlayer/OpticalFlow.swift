import Vision
import CoreVideo
import Metal
import Foundation

/// Estimates dense optical flow between two consecutive decoded video frames
/// using Vision's built-in optical flow request, and hands back a Metal
/// texture suitable for use as a MetalFX `motionTexture` (or for the custom
/// warp/blend fallback in `Shaders.metal`).
///
/// NOTE ON MOTION VECTOR CONVENTION: per Apple's documentation,
/// `VNGenerateOpticalFlowRequest` produces *forward* flow — the observation
/// describes, for each pixel `p` of the request handler's image (our
/// *previous* frame), the displacement to that content's location in the
/// targeted image (our *current* frame), i.e. `currentPosition ≈ p + flow(p)`.
/// MetalFX's temporal effects and the custom warp kernel both want the
/// *backward* convention (`previousPosition = p + flow(p)`), so consumers
/// negate: `FrameInterpolator` sets `motionVectorScaleX/Y = -1.0`, and
/// `warpBlendKernel` in Shaders.metal negates the sampled vector. The texture
/// stored here is the raw (forward) Vision output — negation happens at the
/// point of use, since this is a zero-copy wrap of Vision's own buffer.
final class OpticalFlowEstimator {

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache!
    private let queue = DispatchQueue(label: "SuperResVideoPlayer.OpticalFlow", qos: .userInitiated)

    /// `requestFlow` runs on `queue` (a background thread) but `latestResult`
    /// is read from `Renderer.draw(in:)`, which MTKView calls on its own
    /// render thread — not necessarily main. `latestResult` holds an
    /// `MTLTexture` reference, so an unsynchronized concurrent read/write
    /// here would be a real (if intermittent) ARC-related race, not just a
    /// style nit. `stateLock` guards both `_latestResult` and `_isComputing`.
    private let stateLock = NSLock()
    private var _latestResult: (motionTexture: MTLTexture, cvTexture: CVMetalTexture, flowBuffer: CVPixelBuffer, previousTime: Double, currentTime: Double)?
    private var _isComputing = false
    private var generation: UInt64 = 0

    func reset() {
        stateLock.lock()
        generation &+= 1
        _latestResult = nil
        stateLock.unlock()
    }

    /// Latest computed motion texture (rg32Float, one (dx, dy) pixel-space
    /// vector per source pixel) plus the pair of source-frame timestamps it
    /// was computed from, so the renderer can tell whether it's still valid
    /// for the current previous/current pair. The backing `flowBuffer` is
    /// kept alongside the texture because `motionTexture` is a zero-copy
    /// wrap of Vision's own CVPixelBuffer — retaining the buffer for as long
    /// as the texture is in use keeps the underlying memory alive while the
    /// GPU samples it. Safe to read from any thread.
    var latestResult: (motionTexture: MTLTexture, cvTexture: CVMetalTexture, flowBuffer: CVPixelBuffer, previousTime: Double, currentTime: Double)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestResult
    }

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Kicks off an async optical flow computation for the given pair, if
    /// one isn't already running. Cheap to call every frame; it no-ops while
    /// a computation is in flight so the render loop never blocks on Vision.
    /// Callers should only invoke this when frame interpolation is actually
    /// enabled — Vision's optical flow is genuinely expensive (CPU/ANE), so
    /// running it unconditionally on every decoded frame would waste real
    /// work whenever interpolation is switched off.
    func requestFlow(previous: CVPixelBuffer, current: CVPixelBuffer, previousTime: Double, currentTime: Double) {
        stateLock.lock()
        if _isComputing {
            stateLock.unlock()
            return
        }
        _isComputing = true
        let requestGeneration = generation
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self._isComputing = false
                self.stateLock.unlock()
            }

            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: current, options: [:])
            request.computationAccuracy = .medium
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float

            let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first else { return }
                let flowBuffer = observation.pixelBuffer
                if let texture = self.makeTexture(from: flowBuffer) {
                    self.stateLock.lock()
                    if self.generation == requestGeneration {
                        self._latestResult = (texture.texture, texture.backing, flowBuffer, previousTime, currentTime)
                    }
                    self.stateLock.unlock()
                }
            } catch {
                // Optical flow failed for this pair (e.g. Vision couldn't
                // find enough correspondence). The renderer falls back to
                // showing the nearest real frame when no valid flow exists,
                // so this is a soft failure — just skip this pair.
                print("SuperResVideoPlayer: optical flow failed: \(error)")
            }
        }
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> (texture: MTLTexture, backing: CVMetalTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg32Float,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        // Apple's texture-cache contract asks callers to keep the source
        // buffer alive until the GPU is done with the wrapped texture; the
        // caller stores the CVPixelBuffer alongside this texture in
        // `_latestResult` to satisfy that (same reason Renderer's
        // FrameSample retains its pixelBuffer for color frames).
        return (texture, cvTexture)
    }
}
