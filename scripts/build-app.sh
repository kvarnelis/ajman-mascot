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

for pose_asset in "$REPO_ROOT"/assets/pets/*/{sleep,loaf,stretch,scratch}.webp; do
  [[ -f "$pose_asset" ]] || continue
  pet_id="$(basename "$(dirname "$pose_asset")")"
  mkdir -p "$CONTENTS/Resources/pets/$pet_id"
  cp "$pose_asset" "$CONTENTS/Resources/pets/$pet_id/$(basename "$pose_asset")"
done

ln -sfn "build/Ajman.app" "$REPO_ROOT/Ajman.app"

SIGNING_IDENTITY="Developer ID Application: Kazys Varnelis (PHCL25Z99X)"
SIGNING_SHA1="EECF633E96C251FCD3B4FD76BF9D62DE648826A7"

if security find-identity -v -p codesigning | grep -Fq "$SIGNING_SHA1"; then
  if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"; then
    echo "Signed with Developer ID, hardened runtime, and secure timestamp: $APP"
  elif codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"; then
    echo "WARNING: timestamped signing failed; signed with Developer ID and hardened runtime without a timestamp: $APP" >&2
  elif codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"; then
    echo "WARNING: hardened-runtime signing failed; signed with Developer ID without hardened runtime or timestamp: $APP" >&2
  else
    echo "WARNING: DEVELOPER ID SIGNING FAILED; FALLING BACK TO AD-HOC SIGNING. MACOS MAY TREAT EACH REBUILD AS A NEW APP IDENTITY." >&2
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc: $APP"
  fi
else
  echo "WARNING: DEVELOPER ID IDENTITY IS UNAVAILABLE; FALLING BACK TO AD-HOC SIGNING. MACOS MAY TREAT EACH REBUILD AS A NEW APP IDENTITY." >&2
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc: $APP"
fi

echo "Built: $APP"
