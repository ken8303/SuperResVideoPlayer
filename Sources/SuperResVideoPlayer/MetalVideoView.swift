import SwiftUI
import MetalKit

/// Bridges an MTKView (driven by `Renderer`) into SwiftUI.
struct MetalVideoView: NSViewRepresentable {
    @ObservedObject var playerViewModel: PlayerViewModel

    /// Guards the deferred colour-space apply against duplicate scheduling.
    /// Main-thread only, so a plain static is sufficient.
    private static var applyInFlight = false

    func makeCoordinator() -> Renderer {
        // Deliberately NOT a fresh Renderer per coordinator.
        //
        // SwiftUI rebuilds this representable whenever the surrounding view
        // tree changes shape — and the controls bar gains and loses rows as
        // status lines appear. Each rebuild was constructing another
        // Renderer, and every one of those owns Metal pipeline states, a
        // CVMetalTextureCache, a MetalFX scaler and a Vision optical-flow
        // estimator. The app has exactly one video view, so one renderer for
        // its lifetime is both correct and makes the rebuilds harmless.
        RendererStore.shared.renderer(for: playerViewModel)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        // Must match Renderer's render-pipeline colour attachment.
        // NOT PipelineFormat.metal — CAMetalLayer rejects rgba16Unorm.
        view.colorPixelFormat = PipelineFormat.drawable
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Frame interpolation needs the view to redraw faster than the
        // source video's own frame rate so the synthesized in-between
        // frames actually get displayed. 120fps gives headroom for both the
        // 2x and 3x modes on ProMotion displays; on 60Hz displays this just
        // clamps to 60.
        nsView.preferredFramesPerSecond = playerViewModel.frameInterpolationMultiplier > 1 ? 120 : 60

        configureDynamicRange(on: nsView, hdr: playerViewModel.hdrOutputActive)

        // Push a thread-safe snapshot of the view model's state to the
        // renderer. Renderer.draw(in:) runs on MTKView's render thread and
        // must not read @Published properties directly (data race with
        // main-thread writes) — this is its only supported handoff point.
        context.coordinator.sync(with: playerViewModel)
    }

    /// Tells the window server how to interpret the pixels we hand it.
    ///
    /// This is the step that actually produces HDR on screen. mpv writes
    /// PQ-encoded values into our 16-bit buffers (see
    /// `MPVPlayer.setHDRPassthrough`); those numbers only *mean* HDR once the
    /// layer is tagged with a PQ colour space and opted in to extended
    /// dynamic range. Without both, macOS treats them as ordinary sRGB and
    /// the picture looks washed out and flat.
    private func configureDynamicRange(on view: MTKView, hdr: Bool) {
        // Compare by colour-space *name*, read back from this specific view.
        //
        // A static "already applied" latch is wrong: entering full screen
        // builds a brand-new MTKView, and the latch then suppresses tagging
        // it — so full screen fell back to sRGB and never recovered.
        // Reference-comparing CGColorSpace is also wrong (always unequal).
        let wanted: CFString = hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB
        if let current = (view.layer as? CAMetalLayer)?.colorspace?.name,
           CFStringCompare(current, wanted, []) == .compareEqualTo {
            return
        }
        // The apply below is deferred, so without this several update passes
        // queue up before the first one lands and each re-applies (and
        // re-logs) the same change.
        guard !Self.applyInFlight else { return }
        Self.applyInFlight = true

        // Deferred off the SwiftUI update pass. Reconfiguring the view from
        // inside `updateNSView` re-entrantly invalidates it, which is what
        // was rebuilding the representable (and its coordinator) repeatedly.
        //
        // Note the pixel format is NOT touched — it is constant for exactly
        // that reason. Only the colour space and the EDR opt-in change.
        DispatchQueue.main.async {
            defer { Self.applyInFlight = false }
            view.colorspace = hdr
                ? CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                : CGColorSpace(name: CGColorSpace.sRGB)
            if let layer = view.layer as? CAMetalLayer {
                layer.wantsExtendedDynamicRangeContent = hdr
                let applied = layer.colorspace?.name as String? ?? "nil"
                print("SuperResVideoPlayer: display layer → \(hdr ? "PQ + EDR" : "SDR"); layer colorspace is \(applied)")
            }
        }
    }

}

/// Holds the single `Renderer` for the app so SwiftUI rebuilding the video
/// view can't multiply expensive GPU resources. See `makeCoordinator`.
private final class RendererStore {
    static let shared = RendererStore()
    private var stored: Renderer?

    func renderer(for viewModel: PlayerViewModel) -> Renderer {
        if let stored { return stored }
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("SuperResVideoPlayer: no Metal-capable GPU found on this Mac.")
        }
        let renderer = Renderer(device: device, playerViewModel: viewModel)
        stored = renderer
        return renderer
    }
}
