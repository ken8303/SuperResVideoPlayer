#!/bin/bash
# Builds a self-contained, shareable SuperResVideoPlayer.app:
#  - release build of the Swift package
#  - libmpv and its entire dependency tree copied into Contents/Frameworks
#    with install names rewritten to @rpath (so nothing from /opt/homebrew
#    is needed on the recipient's machine)
#  - ffmpeg + ffprobe bundled into Contents/Helpers (used for MKV subtitle
#    audio extraction and export repackaging), with their deps bundled too
#  - everything ad-hoc code signed, zipped for sharing
#
# Recipient requirements (inherent to the app, not the packaging):
#  - Apple Silicon Mac on macOS 26+
#  - First launch: right-click the app > Open (it's ad-hoc signed, not
#    notarized, so plain double-click is blocked by Gatekeeper)
#
# Usage: bash make-dist.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building (release)…"
# -gnone skips the dsymutil step some Macs block (see make-app.sh); a
# shipped binary doesn't need a dSYM anyway.
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

swift build -c release --scratch-path "$SCRATCH" -Xswiftc -gnone

# Ask SwiftPM where the products are — the layout differs between build
# systems and the default has changed between toolchains.
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" -Xswiftc -gnone --show-bin-path)"
BIN="$BIN_DIR/SuperResVideoPlayer"
BUNDLE_SRC="$BIN_DIR/SuperResVideoPlayer_SuperResVideoPlayer.bundle"
DIST=dist
REPO="$PWD"

# IMPORTANT: stage and sign OUTSIDE the repo.
# If the project lives in an iCloud-synced folder (Desktop & Documents), the
# file provider continuously re-attaches xattrs (com.apple.fileprovider.fpfs,
# com.apple.FinderInfo) to anything created there. codesign then refuses the
# bundle with "resource fork, Finder information, or similar detritus not
# allowed", and clearing the attributes is a race you can't win. /tmp isn't
# managed by the file provider, so the bundle stays clean.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/SuperResVideoPlayerDist.XXXXXX")"
DIST_NEXT="$REPO/.dist.new.$$"
DIST_PREVIOUS="$REPO/.dist.previous.$$"
cleanup() {
  rm -rf "$STAGE" "$DIST_NEXT"
  if [ -d "$DIST_PREVIOUS" ] && [ ! -e "$REPO/$DIST" ]; then
    mv "$DIST_PREVIOUS" "$REPO/$DIST"
  fi
}
trap cleanup EXIT
APP="$STAGE/SuperResVideoPlayer.app"
FRAMEWORKS="$APP/Contents/Frameworks"
HELPERS="$APP/Contents/Helpers"
LICENSES="$APP/Contents/Resources/Licenses"
HOMEBREW_LICENSES="$LICENSES/Homebrew"
FORMULA_MANIFEST="$LICENSES/Homebrew-Formulae.tsv"

rm -rf "$DIST_NEXT" "$DIST_PREVIOUS"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FRAMEWORKS" "$HELPERS" "$LICENSES"

cp "$BIN" "$APP/Contents/MacOS/SuperResVideoPlayer"
cp Info.plist "$APP/Contents/Info.plist"
if [ -d "$BUNDLE_SRC" ]; then
  cp -R "$BUNDLE_SRC" "$APP/Contents/Resources/"
fi

# --- Third-party notices ----------------------------------------------
# Binary distributions include GPL-enabled Homebrew builds. Ship the exact
# license texts installed with the two primary projects and a source notice.
guarded_copy_license() {
  local source="$1"
  local destination="$2"
  if [ ! -f "$source" ]; then
    echo "error: required third-party license missing: $source"
    exit 1
  fi
  cp "$source" "$destination"
}

# Record the exact installed formula, declared SPDX license, upstream source,
# and any license/notice files Homebrew installed at the formula root. This is
# also called while walking dylib dependencies, so transitive libraries are
# documented instead of only mpv and FFmpeg themselves.
record_formula_notice() {
  local formula="$1"
  local prefix version destination metadata license homepage source checksum file
  prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
  [ -d "$prefix" ] || return 0
  prefix="$(cd "$prefix" && pwd -P)"
  version="$(basename "$prefix")"
  destination="$HOMEBREW_LICENSES/$formula-$version"
  [ ! -d "$destination" ] || return 0
  mkdir -p "$destination"

  metadata="$(brew info --json=v2 "$formula")"
  license="$(printf '%s' "$metadata" | jq -r '.formulae[0].license // "unspecified"')"
  homepage="$(printf '%s' "$metadata" | jq -r '.formulae[0].homepage // ""')"
  source="$(printf '%s' "$metadata" | jq -r '.formulae[0].urls.stable.url // ""')"
  checksum="$(printf '%s' "$metadata" | jq -r '.formulae[0].urls.stable.checksum // ""')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$formula" "$version" "$license" "$homepage" "$source" "$checksum" >> "$FORMULA_MANIFEST"

  while IFS= read -r file; do
    cp "$file" "$destination/$(basename "$file")"
  done < <(find "$prefix" -maxdepth 1 -type f \( \
    -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \
    -o -iname 'COPYRIGHT*' \) -print)
}

if [ ! -f THIRD_PARTY_NOTICES.md ]; then
  echo "error: THIRD_PARTY_NOTICES.md is required for binary distribution"
  exit 1
fi
if [ ! -f LICENSE ]; then
  echo "error: LICENSE is required for binary distribution"
  exit 1
fi
cp LICENSE "$APP/Contents/Resources/SuperResVideoPlayer License.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Third-Party Notices.md"
mkdir -p "$HOMEBREW_LICENSES"
printf 'formula\tinstalled-version\tdeclared-license\thomepage\tsource-url\tsource-sha256\n' > "$FORMULA_MANIFEST"

MPV_PREFIX="$(brew --prefix mpv)"
FFMPEG_PREFIX="$(brew --prefix ffmpeg)"
record_formula_notice mpv
record_formula_notice ffmpeg
guarded_copy_license "$MPV_PREFIX/LICENSE.GPL" "$LICENSES/mpv-GPL.txt"
guarded_copy_license "$MPV_PREFIX/LICENSE.LGPL" "$LICENSES/mpv-LGPL.txt"
guarded_copy_license "$FFMPEG_PREFIX/LICENSE.md" "$LICENSES/FFmpeg-LICENSE.md"
for license in COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3; do
  guarded_copy_license "$FFMPEG_PREFIX/$license" "$LICENSES/FFmpeg-$license.txt"
done

# --- App icon ----------------------------------------------------------
# Build AppIcon.icns from the 1024px master (no Xcode asset catalog needed).
if [ -f AppIcon.png ]; then
  echo "==> Building app icon…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz AppIcon.png --out "$ICONSET/icon_${sz}x${sz}.png"     > /dev/null 2>&1
    sips -z $((sz*2)) $((sz*2)) AppIcon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" > /dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "warning: AppIcon.png missing — the app will use the generic icon"
fi

# Optional helper CLIs. The app degrades gracefully without them (subtitles
# for MKV and export-repackaging need them), but bundling means recipients
# install nothing.
for tool in ffmpeg ffprobe; do
  SRC="$(command -v "$tool" || true)"
  if [ -n "$SRC" ]; then
    cp "$SRC" "$HELPERS/$tool"
    chmod u+w "$HELPERS/$tool"
  else
    echo "warning: $tool not found on this machine — the shared app will lack MKV subtitle/export support"
  fi
done

# --- Dependency bundling -----------------------------------------------

is_bundleable() {
  case "$1" in
    /usr/lib/*|/System/*|@*) return 1 ;;   # system libs / already-relative refs
    *) return 0 ;;
  esac
}

# Recursively copy every non-system dylib a binary links against into
# Contents/Frameworks (by basename; the tree is a DAG so this terminates).
collect_deps() {
  local target="$1"
  local dep name cellar_path formula
  for dep in $(otool -L "$target" | tail -n +2 | awk '{print $1}'); do
    is_bundleable "$dep" || continue
    case "$dep" in
      /opt/homebrew/Cellar/*)
        cellar_path="${dep#/opt/homebrew/Cellar/}"
        formula="${cellar_path%%/*}"
        record_formula_notice "$formula"
        ;;
      /opt/homebrew/opt/*)
        cellar_path="${dep#/opt/homebrew/opt/}"
        formula="${cellar_path%%/*}"
        record_formula_notice "$formula"
        ;;
    esac
    name="$(basename "$dep")"
    if [ ! -f "$FRAMEWORKS/$name" ]; then
      if [ ! -f "$dep" ]; then
        echo "warning: dependency not found on disk: $dep (referenced by $target)"
        continue
      fi
      cp "$dep" "$FRAMEWORKS/$name"
      chmod u+w "$FRAMEWORKS/$name"
      collect_deps "$FRAMEWORKS/$name"
    fi
  done
}

# Rewrite a binary's references to bundled libs as @rpath/name.
rewrite_refs() {
  local target="$1"
  local dep name
  for dep in $(otool -L "$target" | tail -n +2 | awk '{print $1}'); do
    is_bundleable "$dep" || continue
    name="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/$name" "$target" 2>/dev/null || true
  done
}

echo "==> Collecting library dependencies…"
collect_deps "$APP/Contents/MacOS/SuperResVideoPlayer"
for tool in "$HELPERS"/*; do
  [ -f "$tool" ] && collect_deps "$tool"
done
echo "    $(ls "$FRAMEWORKS" 2>/dev/null | wc -l | tr -d ' ') libraries bundled"

echo "==> Rewriting install names…"
rewrite_refs "$APP/Contents/MacOS/SuperResVideoPlayer"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SuperResVideoPlayer" 2>/dev/null || true

for lib in "$FRAMEWORKS"/*.dylib; do
  [ -f "$lib" ] || continue
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null || true
  rewrite_refs "$lib"
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done

for tool in "$HELPERS"/*; do
  [ -f "$tool" ] || continue
  rewrite_refs "$tool"
  install_name_tool -add_rpath "@loader_path/../Frameworks" "$tool" 2>/dev/null || true
done

# --- Signing (install_name_tool invalidates signatures) -----------------

echo "==> Code signing (ad-hoc)…"
for lib in "$FRAMEWORKS"/*.dylib; do
  [ -f "$lib" ] && codesign --force --sign - "$lib" > /dev/null 2>&1
done
for tool in "$HELPERS"/*; do
  [ -f "$tool" ] && codesign --force --sign - "$tool" > /dev/null 2>&1
done
# Strip everything codesign considers "detritus" before signing: extended
# attributes, AppleDouble sidecars (._foo), and .DS_Store files. Tools like
# sips/iconutil and plain copies can leave these behind, and codesign then
# fails with "resource fork, Finder information, or similar detritus".
echo "==> Cleaning bundle metadata…"
find "$APP" -name '._*' -delete 2>/dev/null || true
find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
dot_clean -m "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

if ! codesign --force --sign - "$APP" 2>"$STAGE/codesign.err"; then
  echo "error: codesign failed:"
  cat "$STAGE/codesign.err"
  echo
  echo "Remaining extended attributes (these are the likely culprit):"
  xattr -lr "$APP" | head -40
  exit 1
fi

echo "==> Verifying…"
codesign --verify --deep "$APP" && echo "    signature OK"

# Nothing in the bundle may point at Homebrew, or it won't run elsewhere.
LEAKS=0
for target in "$APP/Contents/MacOS/SuperResVideoPlayer" "$FRAMEWORKS"/*.dylib "$HELPERS"/*; do
  [ -f "$target" ] || continue
  if otool -L "$target" 2>/dev/null | tail -n +2 | grep -q "/opt/homebrew\|/usr/local/"; then
    echo "error: $(basename "$target") still references a local Homebrew path"
    LEAKS=1
  fi
done
if [ "$LEAKS" -ne 0 ]; then
  echo "Bundling incomplete — the app would fail on a machine without Homebrew."
  exit 1
fi
echo "    no Homebrew references — bundle is self-contained"

# Zip from the clean staging area (so the archive carries no file-provider
# metadata), then assemble the next dist directory beside the current one.
# Only swap it into place after every copy succeeds, preserving a previously
# working release if any earlier build/sign/verification step fails.
echo "==> Zipping…"
ditto -c -k --keepParent --norsrc "$APP" "$STAGE/SuperResVideoPlayer.zip"

mkdir -p "$DIST_NEXT"
cp "$STAGE/SuperResVideoPlayer.zip" "$DIST_NEXT/"
# A copy of the signed app for local testing. (Copying it back into an
# iCloud-synced folder may re-attach xattrs; that's harmless for running it,
# and the zip above is the artifact you actually distribute.)
ditto "$APP" "$DIST_NEXT/SuperResVideoPlayer.app"

if [ -e "$DIST" ]; then
  mv "$DIST" "$DIST_PREVIOUS"
fi
mv "$DIST_NEXT" "$DIST"
rm -rf "$DIST_PREVIOUS"

echo ""
echo "Done:"
echo "  $DIST/SuperResVideoPlayer.app   <- for local testing"
echo "  $DIST/SuperResVideoPlayer.zip   <- share this"
echo ""
echo "Recipients need: Apple Silicon Mac on macOS 26+. Nothing to install."
echo "First launch: right-click the app > Open (it is ad-hoc signed, not"
echo "notarized). If macOS says it is damaged, they should run:"
echo "  xattr -dc /Applications/SuperResVideoPlayer.app"
