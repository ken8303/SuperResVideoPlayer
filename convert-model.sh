#!/bin/bash
# One-time setup for the "Max" image-enhancer engine (Real-ESRGAN via
# Core ML). Downloads the model weights, converts them, and installs the
# result where the app looks for it. Needs python3 and ~2 GB of disk for
# the temporary Python environment (removable afterwards).
#
# Usage: bash convert-model.sh
set -euo pipefail
cd "$(dirname "$0")"

VENV=.model-venv
WEIGHTS_URL="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth"
# Expected SHA-256 of the upstream realesr-animevideov3.pth release asset.
# Refuse to convert a corrupted or substituted download.
WEIGHTS_SHA256="b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d"
DEST="$HOME/Library/Application Support/SuperResVideoPlayer"

echo "==> Setting up Python environment (first run only)…"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip -q install --upgrade pip
# Pin known-compatible versions for reproducible conversions.
pip -q install "torch==2.5.1" "coremltools==8.1" "numpy<2"

if [ ! -f realesr-animevideov3.pth ]; then
  echo "==> Downloading model weights (~2.4 MB)…"
  curl --fail --location --output realesr-animevideov3.pth "$WEIGHTS_URL"
fi

ACTUAL_SHA256="$(shasum -a 256 realesr-animevideov3.pth | awk '{print $1}')"
echo "==> Model SHA-256: $ACTUAL_SHA256"
if [ -n "$WEIGHTS_SHA256" ] && [ "$ACTUAL_SHA256" != "$WEIGHTS_SHA256" ]; then
  echo "error: checksum mismatch for realesr-animevideov3.pth" >&2
  echo "  expected: $WEIGHTS_SHA256" >&2
  echo "  actual:   $ACTUAL_SHA256" >&2
  echo "Delete the file and re-run, or update WEIGHTS_SHA256 if you trust this build." >&2
  exit 1
fi

echo "==> Converting to Core ML…"
rm -rf RealESRGAN.mlpackage
python3 convert_model.py

echo "==> Installing…"
mkdir -p "$DEST"
rm -rf "$DEST/RealESRGAN.mlpackage"
mv RealESRGAN.mlpackage "$DEST/"

echo ""
echo "Done: $DEST/RealESRGAN.mlpackage"
echo "The 'Max' engine is now available in the app (used during export)."
echo "You can delete $VENV and realesr-animevideov3.pth to reclaim space."
