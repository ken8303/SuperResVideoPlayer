# SuperRes Video Player 1.0

A native macOS video player that plays almost anything and enhances it in
real time with Apple Silicon's MetalFX and on-device AI.

**Download:** `SuperResVideoPlayer.zip` below. Nothing else to install —
the player engine (libmpv) and its media tools are bundled inside the app.

## Requirements

- Apple Silicon Mac (M-series)
- macOS 27 "Golden Gate" or later
- Optional: **Apple Intelligence** enabled, for subtitle translation

## Installing

1. Download and unzip `SuperResVideoPlayer.zip`.
2. Drag **SuperResVideoPlayer.app** to your Applications folder.
3. **Right-click the app → Open**, then confirm.

That third step matters: this build is ad-hoc signed rather than notarized
(notarization requires a paid Apple Developer account), so a normal
double-click is blocked the first time. You only need to do it once.

If macOS claims the app "is damaged", clear the download quarantine flag:

```
xattr -dc /Applications/SuperResVideoPlayer.app
```

## What it does

**Plays everything.** MKV, WebM, AVI, MP4, MOV, FLAC audio — anything the
embedded **libmpv** engine (the same one behind mpv and IINA) understands.
No conversion step, no transcoding.

**Super Resolution.** Real-time upscaling at 1.3x / 1.5x / 2.0x using
Apple's **MetalFX Spatial Scaler**.

**AI Frame Interpolation.** 2x/3x motion smoothing. Vision computes optical
flow, which drives Apple's **MTLFXFrameInterpolator** for 2x midpoints, or a
custom motion-compensated warp kernel for 3x.

**AI Image Enhancer.** Cleans up and reconstructs detail *without changing
resolution*, in three tiers:
- **Classic** — edge-aware denoise + contrast-adaptive sharpening. Free.
- **Neural** — MetalFX ML reconstruction at 2x, resampled back to native.
- **Max** — Real-ESRGAN via Core ML. Export only, and needs an optional
  model that is not bundled; Classic and Neural need nothing.

**AI Subtitles.** On-device transcription with macOS 27's
SpeechAnalyzer — long-form audio with per-word timing. Language models
download on demand; installed ones are marked in the picker. Export as
`.srt`.

**AI Subtitle Translation.** Translate generated subtitles (e.g. Japanese
audio → Traditional Chinese subtitles) entirely on-device via Apple
Intelligence.

**Enhanced export.** Re-render a whole file with Super Resolution and frame
interpolation applied, encoded to HEVC `.mp4` with AAC audio.
A **Test 10s** button renders a short clip so you can compare settings
quickly. Export is slower than real time — optical flow dominates.

**Audio & subtitle tracks.** Multi-track files — MKVs with several audio
languages, commentary, or embedded subtitles — get track pickers in the
controls bar, the video's right-click menu, and the **Video** menu. The
selected audio track is the one transcribed and exported, not just the one
you hear.

**Player basics.** Keyboard shortcuts (Space, ←/→ seek, ↑/↓ volume, M mute,
F fullscreen), drag-and-drop, fullscreen with auto-hiding controls, settings
reachable from the menu bar or a right-click on the video (so they stay
available in fullscreen), and settings that persist between launches.

**Live pipeline stats.** A readout showing input→output resolution and real
vs. synthesized frames per second, so you can confirm the enhancements are
actually running.

## Known limitations

- Frame interpolation repurposes game technology: motion vectors come from
  optical flow and depth is a flat constant, so expect occasional ghosting
  around fast motion, especially at 3x. During playback interpolation only
  engages when Vision keeps up; export always interpolates every frame pair.
- Export ignores rotation metadata and doesn't tag HDR color primaries —
  fine for standard SDR files, wrong for rotated phone footage or HDR.
- Subtitle cue breaks use a pause/length heuristic, not sentence detection.
- Translation quality is on-device-LLM grade: good for following along, not
  fansub grade. A few lines may be skipped by the model's content filter.
- Video is processed as 8-bit; HDR sources are tone-mapped to SDR.
- Subtitles need an audio track — video-only files report this clearly.

## Licenses

App source © the author. The bundled **mpv/libmpv** and **FFmpeg**
components are licensed under LGPL/GPL; see their projects for terms. The
optional Max engine uses **Real-ESRGAN** (BSD-3-Clause), which is downloaded
and converted locally and is not included in this build.
