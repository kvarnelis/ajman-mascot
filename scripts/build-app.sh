#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# --disable-sandbox avoids SwiftPM's inner sandbox conflicting with an outer
# agent sandbox (sandbox_apply: Operation not permitted). No build plugins here,
# so this is safe and keeps agent builds deterministic.
swift build -c release --disable-sandbox

APP="$REPO_ROOT/build/Ajman.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$REPO_ROOT/.build/release/Ajman" "$CONTENTS/MacOS/Ajman"
cp "$REPO_ROOT/.build/release/ajman-hook" "$CONTENTS/MacOS/ajman-hook"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.varnelis.Ajman</string>
  <key>CFBundleName</key><string>Ajman</string>
  <key>CFBundleExecutable</key><string>Ajman</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

mkdir -p "$CONTENTS/Resources/pets"
for pet_id in ajman winnie; do
  ASSET_DIR="$HOME/.codex/pets/$pet_id"
  if [[ -f "$ASSET_DIR/pet.json" && -f "$ASSET_DIR/spritesheet.webp" ]]; then
    mkdir -p "$CONTENTS/Resources/pets/$pet_id"
    cp "$ASSET_DIR/pet.json" "$CONTENTS/Resources/pets/$pet_id/pet.json"
    cp "$ASSET_DIR/spritesheet.webp" "$CONTENTS/Resources/pets/$pet_id/spritesheet.webp"
  elif [[ "$pet_id" == "ajman" ]]; then
    echo "Required bundled fallback is missing: $ASSET_DIR" >&2
    exit 1
  fi
done

for pose_asset in "$REPO_ROOT"/assets/pets/*/{sleep,loaf,stretch}.webp; do
  [[ -f "$pose_asset" ]] || continue
  pet_id="$(basename "$(dirname "$pose_asset")")"
  mkdir -p "$CONTENTS/Resources/pets/$pet_id"
  cp "$pose_asset" "$CONTENTS/Resources/pets/$pet_id/$(basename "$pose_asset")"
done

ln -sfn "build/Ajman.app" "$REPO_ROOT/Ajman.app"
codesign --force --sign - "$APP"
echo "Built and signed: $APP"
