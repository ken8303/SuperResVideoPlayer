# SuperRes Video Player 1.3

A native macOS video player that plays almost anything and enhances video in
real time using Apple Silicon, MetalFX, Vision, and optional on-device AI.

**Download:** `SuperResVideoPlayer.zip` below. The player engine and media
tools are bundled, so users do not need to install Homebrew or other software.

## Highlights

### A complete, responsive interface

The player controls now remain fully visible without scrolling. The video area
shrinks first when the window is resized, and the minimum/default window sizes
keep enhancement, interpolation, subtitle, translation, and export controls
available. Playback time updates are isolated from the larger settings tree,
reducing unnecessary SwiftUI work during playback.

### More reliable playback and HDR handling

- HDR10 and HLG playback use the 16-bit rendering path when supported.
- HDR passthrough now requires real display headroom; otherwise BT.2390 tone
  mapping is used to avoid clipped highlights.
- Playback time is cached instead of synchronously queried from mpv at display
  refresh rate.
- Player shutdown waits safely for the event thread, preventing use-after-free
  crashes during quit or rapid teardown.
- Renderer instance accounting and shared state are thread-safe.
- Neural enhancement correctly stages frames smaller than its tile size,
  preventing stale pixels from a previous frame.

### Safer export

- Export now honours cancellation and writer backpressure and finalizes only
  after video and audio inputs are complete.
- Rotation metadata is retained and correctly scaled in enhanced exports.
- Output dimensions are encoder-aligned and capped at Metal's safe limit.
- HDR export is blocked with a clear message until a color-managed HDR export
  path is available, rather than silently producing incorrect SDR output.

### Better subtitles and imports

- Subtitle lookup uses an efficient binary search and handles overlapping cue
  boundaries consistently.
- Cue grouping no longer creates overlapping timestamps after length-based
  splits.
- Speech model downloads, cancellation, and stale status updates are safer.
- Media imports cannot publish the result of an older cancelled request over a
  newer selection.

### Distribution and open source

- SuperResVideoPlayer is now licensed under GPL-3.0-or-later.
- Release packages include the application license, third-party notices, exact
  Homebrew formula versions, declared licenses, source URLs and checksums, and
  available installed license files.
- Release creation is atomic: a failed build cannot erase the previous good
  package.
- ZIP archives no longer contain macOS metadata sidecars.
- The bundle identifier is now `io.github.ken8303.SuperResVideoPlayer`.

## Requirements

- Apple Silicon Mac
- macOS 26 or later
- Apple Intelligence enabled for subtitle translation

## Installation

1. Download and unzip `SuperResVideoPlayer.zip`.
2. Drag **SuperResVideoPlayer.app** to Applications, replacing an older copy.
3. On first launch, right-click the app and choose **Open**, then confirm.

The app is ad-hoc signed rather than Apple-notarized. If macOS reports that it
is damaged, run:

```sh
xattr -dc /Applications/SuperResVideoPlayer.app
```

## Known limitations

- Export currently supports SDR output only; HDR export is intentionally
  blocked.
- Multi-channel audio is encoded as stereo AAC during export.
- Frame interpolation can show artifacts around fast or complex motion.
- Subtitle translation quality depends on Apple's on-device model.
- The optional Real-ESRGAN Max engine is export-only and requires a separate
  local model installation.

## Verification

- 42 automated tests pass.
- The release app is self-contained with no Homebrew library references.
- The ZIP passes archive-integrity and deep code-signature verification after
  extraction.
