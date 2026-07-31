#!/usr/bin/env python3
"""
Survey a video library to decide whether a hybrid AVFoundation/libmpv decode
path is worth building for HDR support.

Background: SuperResVideoPlayer renders through mpv's *software* render API,
which outputs 8 bits per channel, so HDR sources are tone-mapped to SDR before
the Metal pipeline sees them. VideoToolbox, by contrast, decodes HDR straight
to 10-bit CVPixelBuffers — but only for containers AVFoundation can open
(essentially MP4/MOV/M4V, not MKV/WebM/AVI).

So the question this answers is narrow and practical:

    Of the HDR files you actually own, what share could a hybrid path serve?

  - High share  -> a hybrid decode path buys you real HDR on most of your
                   library, and is probably worth the added complexity.
  - Low share   -> your HDR content lives in MKV, AVFoundation can't help,
                   and the work would mostly not pay off.

Usage:
    python3 probe-hdr.py [directory ...]      # defaults to ~/Movies
    python3 probe-hdr.py --csv report.csv ~/Movies ~/Downloads

Requires ffprobe (bundled with ffmpeg: `brew install ffmpeg`).
Reads only metadata — never modifies or transcodes anything.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from collections import Counter

VIDEO_EXTS = {
    ".mp4", ".m4v", ".mov",                 # AVFoundation-native
    ".mkv", ".webm", ".avi", ".ts", ".m2ts",  # mpv-only
    ".flv", ".wmv", ".vob", ".mpg", ".mpeg", ".ogv", ".rmvb",
}

# Containers AVFoundation/VideoToolbox can open directly. Everything else has
# to go through libmpv, which caps us at 8-bit.
AVF_EXTS = {".mp4", ".m4v", ".mov"}

# Transfer characteristics that mean HDR.
HDR_TRANSFERS = {"smpte2084", "arib-std-b67"}   # PQ (HDR10/DV), HLG


def find_ffprobe():
    # Prefer a copy bundled next to the app, then PATH, then Homebrew.
    for candidate in (
        "./dist/SuperResVideoPlayer.app/Contents/Helpers/ffprobe",
        shutil.which("ffprobe"),
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
    ):
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def probe(ffprobe, path):
    """Return a dict describing the file's first video stream, or None."""
    try:
        out = subprocess.run(
            [ffprobe, "-v", "quiet", "-print_format", "json",
             "-show_streams", "-select_streams", "v:0", path],
            capture_output=True, text=True, timeout=60,
        )
        streams = json.loads(out.stdout or "{}").get("streams", [])
        if not streams:
            return None
        s = streams[0]
    except Exception:
        return None

    pix_fmt = s.get("pix_fmt", "") or ""
    # ffprobe reports bit depth directly on most builds; infer from the pixel
    # format name otherwise (e.g. yuv420p10le -> 10).
    depth = s.get("bits_per_raw_sample")
    if depth:
        try:
            depth = int(depth)
        except ValueError:
            depth = None
    if not depth:
        depth = 10 if "10" in pix_fmt else (12 if "12" in pix_fmt else 8)

    transfer = (s.get("color_transfer") or "").lower()
    primaries = (s.get("color_primaries") or "").lower()

    is_hdr = transfer in HDR_TRANSFERS or (primaries == "bt2020" and depth >= 10)

    return {
        "codec": s.get("codec_name", "?"),
        "width": s.get("width", 0),
        "height": s.get("height", 0),
        "pix_fmt": pix_fmt,
        "depth": depth,
        "transfer": transfer or "-",
        "primaries": primaries or "-",
        "is_hdr": is_hdr,
        "hdr_kind": ("HDR10/PQ" if transfer == "smpte2084"
                     else "HLG" if transfer == "arib-std-b67"
                     else "wide-gamut" if is_hdr else ""),
    }


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("dirs", nargs="*", default=None,
                    help="directories to scan (default: ~/Movies)")
    ap.add_argument("--csv", help="also write a full per-file CSV report")
    args = ap.parse_args()

    dirs = args.dirs or [os.path.expanduser("~/Movies")]

    ffprobe = find_ffprobe()
    if not ffprobe:
        sys.exit("error: ffprobe not found. Install it with: brew install ffmpeg")

    files = []
    for d in dirs:
        d = os.path.expanduser(d)
        if not os.path.isdir(d):
            print(f"warning: not a directory, skipping: {d}", file=sys.stderr)
            continue
        for root, _, names in os.walk(d):
            for n in names:
                if os.path.splitext(n)[1].lower() in VIDEO_EXTS:
                    files.append(os.path.join(root, n))

    if not files:
        sys.exit(f"No video files found in: {', '.join(dirs)}")

    # flush so this lands before the stderr progress counter
    print(f"Scanning {len(files)} file(s) with ffprobe…\n", flush=True)

    rows = []
    for i, path in enumerate(sorted(files), 1):
        print(f"\r  {i}/{len(files)}", end="", file=sys.stderr, flush=True)
        info = probe(ffprobe, path)
        if not info:
            continue
        ext = os.path.splitext(path)[1].lower()
        info["path"] = path
        info["ext"] = ext
        info["avf"] = ext in AVF_EXTS
        rows.append(info)
    print("\r" + " " * 24 + "\r", end="", file=sys.stderr)

    hdr = [r for r in rows if r["is_hdr"]]
    hdr_avf = [r for r in hdr if r["avf"]]
    hdr_mpv = [r for r in hdr if not r["avf"]]

    # ---- per-file listing of the HDR titles (the ones that matter) --------
    if hdr:
        print("HDR files found")
        print("-" * 78)
        for r in sorted(hdr, key=lambda r: (not r["avf"], r["path"])):
            route = "AVFoundation" if r["avf"] else "mpv only"
            name = os.path.basename(r["path"])
            if len(name) > 42:
                name = name[:39] + "…"
            print(f"  {name:<42} {r['hdr_kind']:<11} {r['depth']}-bit  "
                  f"{r['ext']:<6} {route}")
        print()

    # ---- summary ---------------------------------------------------------
    print("Summary")
    print("-" * 78)
    print(f"  Total video files scanned : {len(rows)}")
    print(f"  HDR files                 : {len(hdr)}")
    print(f"  SDR files                 : {len(rows) - len(hdr)}")

    if not hdr:
        print("\n  VERDICT: no HDR content found in the scanned folders.")
        print("  A hybrid decode path would give you nothing today. Point this")
        print("  at wherever your HDR files actually live and re-run.")
    else:
        share = 100.0 * len(hdr_avf) / len(hdr)
        print(f"\n  HDR in MP4/MOV (AVFoundation can decode) : {len(hdr_avf)}"
              f"  ({share:.0f}%)")
        print(f"  HDR in MKV/other (mpv only, stays 8-bit) : {len(hdr_mpv)}"
              f"  ({100 - share:.0f}%)")

        print()
        if share >= 70:
            print(f"  VERDICT: worth building. {share:.0f}% of your HDR content")
            print("  could get true 10-bit HDR through a VideoToolbox path,")
            print("  with libmpv still handling everything else.")
        elif share >= 30:
            print(f"  VERDICT: partial win. Only {share:.0f}% of your HDR content")
            print("  would benefit. Worth it if those are the files you care")
            print("  about most — otherwise the second decode path is a lot of")
            print("  complexity for a minority of your library.")
        else:
            print(f"  VERDICT: probably not worth it. Just {share:.0f}% of your HDR")
            print("  content is in a container AVFoundation can open; the rest")
            print("  is MKV/WebM and would stay 8-bit regardless. Remuxing those")
            print("  to MP4 first (stream copy, lossless) would change this.")

    # ---- context ---------------------------------------------------------
    codecs = Counter(r["codec"] for r in hdr)
    if codecs:
        print("\n  HDR codecs: " + ", ".join(f"{c} ×{n}" for c, n in codecs.most_common()))

    if args.csv:
        import csv
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["path", "container", "codec", "width", "height",
                        "pix_fmt", "bit_depth", "transfer", "primaries",
                        "is_hdr", "avfoundation_readable"])
            for r in sorted(rows, key=lambda r: r["path"]):
                w.writerow([r["path"], r["ext"], r["codec"], r["width"],
                            r["height"], r["pix_fmt"], r["depth"],
                            r["transfer"], r["primaries"],
                            "yes" if r["is_hdr"] else "no",
                            "yes" if r["avf"] else "no"])
        print(f"\n  Full report written to {args.csv}")


if __name__ == "__main__":
    main()
