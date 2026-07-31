# SuperRes Video Player 1.1 (pre-release)

A native macOS video player that plays almost anything and enhances it in
real time with Apple Silicon's MetalFX and on-device AI.

**Download:** `SuperResVideoPlayer.zip` below. Nothing else to install —
the player engine (libmpv) and its media tools are bundled inside the app.

> **Pre-release.** This build adds HDR10 output, multi-track audio and
> subtitle selection, and lowers the requirement to macOS 26. Please report
> anything that misbehaves.

## What's new since 1.0

**Audio track selection.** Files with several audio tracks — a second
language, a director's commentary — now get an **Audio** picker. The
selected track is also the one used for subtitle generation and for export,
so transcribing a Japanese dub no longer silently transcribes the English
original.

**Embedded subtitle tracks.** Subtitles carried inside the file (the
`.srt`/ASS streams in most MKVs) can now be chosen or switched off. They
render through the player engine, independently of the AI subtitles. When an
embedded track is showing, the AI subtitle overlay steps aside so the two
can't stack on top of each other.

**HDR10 output, without giving up the enhancements.** The playback pipeline
now runs at 16 bits per channel instead of 8, which is what makes this
possible: HDR10 and HLG files are passed through as PQ to a display with
real extended dynamic range, while Super Resolution, frame interpolation and
the image enhancer keep working on them. On an ordinary SDR display — or an
"HDR ready" monitor whose actual peak brightness is around SDR levels — the
signal is tone-mapped instead, with the BT.2390 curve and per-scene peak
detection rather than a naive clip. The controls bar reports which is
happening, along with the file's bit depth and mastering luminance.

**Runs on macOS 26.** The previous build required macOS 27; nothing in the
app actually needed it. macOS 27 still gives better on-device subtitle
translation.

**CJK subtitles render properly.** Recent macOS moved its bundled Chinese
font into a protected location the subtitle renderer can't open, so Chinese,
Japanese and Korean subtitles appeared as empty boxes. The player now uses a
system font it can actually load.

**Settings without the controls bar.** All the enhancement and track
settings are now reachable two more ways: **right-click on the video**, and
a new **Video** menu in the menu bar. Both work in full screen after the
controls bar auto-hides — previously the only way back to the settings was
to leave full screen.

**Fixes**
- Menu-bar and context menus no longer flicker or refuse clicks during
  playback (they were rebuilding several times a second).
- Fixed a crash when the playback engine was torn down while the app kept
  running — two threads could free the same handle.
- Entering full screen no longer rebuilds the video view, which previously
  reset the picture and lost the display's colour-space setting.
- The video view no longer multiplies GPU resources when the window's
  layout changes.
- Subtitle and export caches are keyed per audio track, so switching tracks
  can't reuse the previous track's extracted audio.
- Corrected the docs: export re-encodes audio to AAC rather than copying it
  through, and audio is extracted as 16 kHz WAV, not `.m4a`.

## Requirements

- Apple Silicon Mac (M-series)
- macOS 26 or later (macOS 27 gives better on-device subtitle translation)
- Optional: **Apple Intelligence** enabled, for subtitle translation

## Installing

1. Download and unzip `SuperResVideoPlayer.zip`.
2. Drag **SuperResVideoPlayer.app** to your Applications folder, replacing
   any earlier version.
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

**Audio & subtitle tracks.** Pickers for the file's own audio and embedded
subtitle streams, in the controls bar, the right-click menu and the Video
menu.

**AI Subtitles.** On-device transcription with the SpeechAnalyzer API —
long-form audio with per-word timing. Language models download on demand;
installed ones are marked in the picker. Export as `.srt`.

**AI Subtitle Translation.** Translate generated subtitles (e.g. Japanese
audio → Traditional Chinese subtitles) entirely on-device via Apple
Intelligence.

**Enhanced export.** Re-render a whole file with Super Resolution and frame
interpolation applied, encoded to HEVC `.mp4` with AAC audio. A **Test 10s**
button renders a short clip so you can compare settings quickly. Export is
slower than real time — optical flow dominates.

**Player basics.** Keyboard shortcuts (Space, ←/→ seek, ↑/↓ volume, M mute,
F fullscreen), drag-and-drop, fullscreen with auto-hiding controls, and
settings that persist between launches.

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
- **HDR output needs a display with real headroom.** HDR10 and HLG files
  play at full bit depth through a 16-bit pipeline, and the enhancements
  still work on them. But passthrough only engages when an attached display
  actually reports extended dynamic range — on an ordinary SDR panel, or an
  "HDR ready" monitor whose peak brightness is around SDR levels, the signal
  is tone-mapped with the BT.2390 curve instead. That is the correct result:
  sending 1000-nit content to a 300-nit panel clips highlights to white.
  The controls bar says which is happening.
- Multi-channel audio is downmixed to stereo AAC on export, so 5.1 and
  Atmos tracks lose their surround channels in the exported file.
- Subtitles need an audio track — video-only files report this clearly.
- The subtitle font covers Chinese well; a few Traditional-only or Korean
  glyphs may fall back. Bundling Noto Sans CJK would remove this entirely.

## Licenses

App source © the author. The bundled **mpv/libmpv** and **FFmpeg**
components are licensed under LGPL/GPL; see their projects for terms. The
optional Max engine uses **Real-ESRGAN** (BSD-3-Clause), which is downloaded
and converted locally and is not included in this build.
