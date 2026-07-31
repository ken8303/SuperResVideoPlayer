#!/bin/bash
# Runs the SuperResCore unit tests.
#
# Uses the classic ("native"/llbuild) build system: Xcode 27's newer
# "swiftbuild" system codesigns the .xctest bundle and fails on some Macs
# with "resource fork, Finder information, or similar detritus not allowed".
# `-Xswiftc -gnone` skips the debug-symbol/dsymutil step some Macs also block.
set -euo pipefail
cd "$(dirname "$0")"
# Build artefacts go OUTSIDE the project folder.
#
# This repo lives in an iCloud-synced directory (Desktop & Documents), whose
# file provider continuously re-attaches xattrs to anything created there.
# codesign then refuses with "resource fork, Finder information, or similar
# detritus not allowed" — a race that can't be won in-place. /tmp isn't
# managed by the file provider, so builds there stay clean. This also keeps
# multi-GB build products from being uploaded to iCloud.
SCRATCH="${TMPDIR:-/tmp}"
SCRATCH="${SCRATCH%/}/SuperResVideoPlayer-build"   # TMPDIR ends in "/" on macOS
mkdir -p "$SCRATCH"

swift test --build-system native --scratch-path "$SCRATCH" -Xswiftc -gnone
