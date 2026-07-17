#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/assets/imports/2026-06-30 original/ig_016eb0fa9df4c654016a4471a68d0c8190a3760efd238f41e7.png"
OUTPUT_DIR="${1:-$REPO_ROOT/build/icon}"
ICONSET="$OUTPUT_DIR/Ajman.iconset"
HEAD_SOURCE="$OUTPUT_DIR/Ajman-head-source.png"
ALPHA_MASK="$OUTPUT_DIR/Ajman-head-alpha.png"
CROP="$OUTPUT_DIR/Ajman-head-crop.png"

command -v magick >/dev/null || { echo "ImageMagick 'magick' is required." >&2; exit 1; }
command -v iconutil >/dev/null || { echo "Apple 'iconutil' is required." >&2; exit 1; }
[[ -f "$SOURCE" ]] || { echo "Canonical Ajman portrait is missing: $SOURCE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# A square, centered 500px crop around Ajman's head. This includes both ears,
# the authentic tipped left ear (viewer's right), whiskers, and the top of his
# white bib. It never scales or reshapes the source artwork.
magick "$SOURCE" -crop 500x500+290+100 +repage "$CROP"

# The portrait's green field is not perfectly uniform. Build alpha from green
# dominance instead of one exact color, then un-composite the sampled green
# (roughly 0.04, 0.95, 0.07) out of edge pixels. This removes green fringe while
# leaving Ajman's yellow-green eyes and every marking untouched.
magick "$CROP" -fx 'max(0,min(1,1-(g-max(r,b))/0.62))' "$ALPHA_MASK"
magick "$CROP" "$ALPHA_MASK" \
  \( -clone 0,1 -fx 'v.r<0.02?0:max(0,min(1,(u.r-(1-v.r)*0.04)/max(v.r,0.02)))' \) \
  \( -clone 0,1 -fx 'v.r<0.02?0:max(0,min(1,(u.g-(1-v.r)*0.95)/max(v.r,0.02)))' \) \
  \( -clone 0,1 -fx 'v.r<0.02?0:max(0,min(1,(u.b-(1-v.r)*0.07)/max(v.r,0.02)))' \) \
  \( -clone 1 \) \
  -delete 0,1 -combine "$HEAD_SOURCE"

make_slot() {
  local pixels="$1"
  local name="$2"
  # PNG32 keeps even the tiny slots in true-color RGBA; iconutil rejects
  # palette-optimized PNGs on some macOS releases.
  magick "$HEAD_SOURCE" -filter Lanczos -resize "${pixels}x${pixels}" "PNG32:$ICONSET/$name"
}

make_slot 16 icon_16x16.png
make_slot 32 icon_16x16@2x.png
make_slot 32 icon_32x32.png
make_slot 64 icon_32x32@2x.png
make_slot 128 icon_128x128.png
make_slot 256 icon_128x128@2x.png
make_slot 256 icon_256x256.png
make_slot 512 icon_256x256@2x.png
make_slot 512 icon_512x512.png
make_slot 1024 icon_512x512@2x.png

GENERATED_ICNS="$OUTPUT_DIR/Ajman-generated.icns"
if iconutil --convert icns --output "$GENERATED_ICNS" "$ICONSET"; then
  mv "$GENERATED_ICNS" "$OUTPUT_DIR/Ajman.icns"
elif [[ -s "$OUTPUT_DIR/Ajman.icns" ]]; then
  rm -f "$GENERATED_ICNS"
  echo "WARNING: iconutil rejected the regenerated iconset; preserving the existing Ajman.icns." >&2
else
  exit 1
fi
echo "Built icon: $OUTPUT_DIR/Ajman.icns"
