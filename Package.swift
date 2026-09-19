// swift-tools-version:6.2
// (6.2+ is required for PackageDescription to expose `.macOS(.v26)` below.)
import PackageDescription
import Foundation

// Resolve Info.plist relative to this manifest file's own location (not the
// current working directory), so the linker flag below works whether the
// package is built with `swift build` from an arbitrary directory or opened
// directly in Xcode (which uses a different working directory at link time).
let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Info.plist")
    .path

let package = Package(
    name: "SuperResVideoPlayer",
    platforms: [
        // MetalFX Frame Interpolation (MTLFXFrameInterpolator, part of
        // Metal 4) requires macOS 26+. The Super Resolution spatial scaler
        // alone only needs macOS 13/14, but since this target now also uses
        // frame interpolation, the whole app needs macOS 26 as its floor.
        // If `.v26` isn't recognized, your installed Swift toolchain
        // predates macOS 26 SDK support — install Xcode 26+ or a matching
        // toolchain, or bump swift-tools-version above if Apple ships a
        // newer PackageDescription API for it.
        .macOS(.v26)
    ],
    targets: [
        // libmpv (the engine inside mpv/IINA) handles demuxing and decoding
        // of every container/codec ffmpeg supports — MKV, WebM, FLAC, ... —
        // natively, with no conversion step. Install it with:
        //     brew install mpv
        // pkg-config (via mpv.pc) supplies the header/library search paths.
        .systemLibrary(
            name: "Cmpv",
            path: "Sources/Cmpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .executableTarget(
            name: "SuperResVideoPlayer",
            dependencies: ["Cmpv"],
            path: "Sources/SuperResVideoPlayer",
            resources: [
                // Ship the raw shader source in the module's resource
                // bundle. Xcode compiles .metal resources into a
                // default.metallib, but command-line `swift build` does NOT
                // — it just copies the file. Renderer.loadShaderLibrary()
                // handles both: it tries the precompiled metallib first,
                // then compiles this source at runtime. `.copy` (not
                // `.process`) guarantees the raw file is present verbatim.
                .copy("Shaders.metal")
            ],
            swiftSettings: [
                // tools-version 6.x defaults to Swift 6 language mode
                // (strict concurrency), which this codebase isn't audited
                // for — it uses manual locking (NSLock) and main-queue hops
                // instead. Stay in Swift 5 mode until a proper Sendable/
                // actor-isolation pass is done.
                .swiftLanguageMode(.v5),
                // Fallback header search paths for libmpv when pkg-config
                // isn't installed (SwiftPM then can't resolve mpv.pc).
                // Harmless if the directories don't exist.
                .unsafeFlags([
                    "-Xcc", "-I/opt/homebrew/include",   // Homebrew, Apple Silicon
                    "-Xcc", "-I/usr/local/include"       // Homebrew, Intel
                ])
            ],
            linkerSettings: [
                // Fallback library search paths, same reason as above.
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/lib"
                ]),
                // Embeds Info.plist (at the package root) into the binary's
                // __TEXT,__info_plist section. Plain SPM executables don't
                // get an Info.plist the way an .app bundle does, but the
                // Speech framework (used by the AI Subtitle Generator)
                // still requires NSSpeechRecognitionUsageDescription to be
                // discoverable there, or macOS kills the process instead of
                // prompting for permission. This is the standard workaround
                // for CLI-style Swift executables that need a TCC privacy
                // permission. If you convert this to a proper Xcode "App"
                // target later, use its native Info.plist instead and you
                // can drop this.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        ),
        .testTarget(
            name: "SuperResVideoPlayerTests",
            dependencies: ["SuperResVideoPlayer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
