#!/bin/bash
# Builds the SwiftPM executable and wraps it in a minimal .app bundle.
#
# Why: several system frameworks assume a real app bundle — TCC permission
# prompts, the Translation framework's model-download UI, Dock/menu-bar
# integration. A bare SPM binary launched from a terminal has none of that
# identity, which causes hangs (e.g. Translation's consent sheet blocking
# the main thread invisibly) and hidden dialogs.
#
# Usage:
#   bash make-app.sh          # build + launch (logs go to the terminal)
set -euo pipefail
cd "$(dirname "$0")"

# -gnone disables debug-info (and thus the post-link dsymutil step). Some
# Macs block dsymutil from writing the .dSYM bundle ("cannot create Plist:
# Operation not permitted"), which would otherwise fail the build. Debug
# symbols aren't needed just to run the app.
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

swift build --scratch-path "$SCRATCH" -Xswiftc -gnone

# Ask SwiftPM where it actually put the products: the layout differs between
# build systems ("debug/" for the native one, "out/Products/Debug/" for the
# Xcode one) and the default has changed between toolchains.
BIN_DIR="$(swift build --scratch-path "$SCRATCH" -Xswiftc -gnone --show-bin-path)"
BIN="$BIN_DIR/SuperResVideoPlayer"
BUNDLE_SRC="$BIN_DIR/SuperResVideoPlayer_SuperResVideoPlayer.bundle"
# The .app is assembled and signed in the scratch dir too — signing it
# inside the iCloud-synced project folder is what fails.
APP="$SCRATCH/SuperResVideoPlayer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/SuperResVideoPlayer"
cp Info.plist "$APP/Contents/Info.plist"

# SPM resource bundle (compiled shaders etc.) — Bundle.module looks for it
# in Contents/Resources.
if [ -d "$BUNDLE_SRC" ]; then
  cp -R "$BUNDLE_SRC" "$APP/Contents/Resources/"
fi

# Ad-hoc signature: enough for local use; TCC and system services want
# *some* stable code identity.
codesign --force --sign - "$APP"

echo "Built $APP"

# Launch the binary inside the bundle directly (instead of `open`) so
# stdout/stderr still print to this terminal. Bundle identity is derived
# from the executable's location, so this still counts as a real app.
exec "$APP/Contents/MacOS/SuperResVideoPlayer"
