#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(sed -nE 's/^[[:space:]]*static let version[[:space:]]*=[[:space:]]*AppVersion\("([^"]+)"\)![[:space:]]*$/\1/p' "$REPO_ROOT/Sources/Ajman/AppVersion.swift")"
if [[ -z "$VERSION" || "$VERSION" == *$'\n'* ]] || ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){2}(-[0-9A-Za-z.-]+)?$'; then
  echo "Could not read one valid AppVersion literal from Sources/Ajman/AppVersion.swift" >&2
  exit 1
fi

# --disable-sandbox avoids SwiftPM's inner sandbox conflicting with an outer
# agent sandbox (sandbox_apply: Operation not permitted). No build plugins here,
# so this is safe and keeps agent builds deterministic.
swift build -c release --disable-sandbox

"$REPO_ROOT/scripts/build-icon.sh" "$REPO_ROOT/build/icon"

APP="$REPO_ROOT/build/Ajman.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$REPO_ROOT/.build/release/Ajman" "$CONTENTS/MacOS/Ajman"
cp "$REPO_ROOT/.build/release/ajman-hook" "$CONTENTS/MacOS/ajman-hook"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.varnelis.Ajman</string>
  <key>CFBundleName</key><string>Ajman</string>
  <key>CFBundleExecutable</key><string>Ajman</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Ajman.icns</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "$REPO_ROOT/build/icon/Ajman.icns" "$CONTENTS/Resources/Ajman.icns"

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

for pose_asset in "$REPO_ROOT"/assets/pets/*/{sleep,loaf,stretch,scratch,groom,scream,run-left,run-right}.webp; do
  [[ -f "$pose_asset" ]] || continue
  pet_id="$(basename "$(dirname "$pose_asset")")"
  mkdir -p "$CONTENTS/Resources/pets/$pet_id"
  cp "$pose_asset" "$CONTENTS/Resources/pets/$pet_id/$(basename "$pose_asset")"
done

ln -sfn "build/Ajman.app" "$REPO_ROOT/Ajman.app"

SIGNING_IDENTITY="Developer ID Application: Kazys Varnelis (PHCL25Z99X)"
SIGNING_SHA1="EECF633E96C251FCD3B4FD76BF9D62DE648826A7"
SIGN_TARGETS=("$CONTENTS/MacOS/ajman-hook" "$APP")

sign_targets() {
  local target
  for target in "${SIGN_TARGETS[@]}"; do
    codesign --force "$@" --sign "$SIGNING_IDENTITY" "$target" || return 1
  done
}

sign_targets_adhoc() {
  local target
  for target in "${SIGN_TARGETS[@]}"; do
    codesign --force --sign - "$target" || return 1
  done
}

if security find-identity -v -p codesigning | grep -Fq "$SIGNING_SHA1"; then
  if sign_targets --options runtime --timestamp; then
    echo "Signed with Developer ID, hardened runtime, and secure timestamp: $APP"
  elif sign_targets --options runtime --timestamp=none; then
    echo "WARNING: timestamped signing failed; signed with Developer ID and hardened runtime without a timestamp: $APP" >&2
  elif sign_targets --timestamp=none; then
    echo "WARNING: hardened-runtime signing failed; signed with Developer ID without hardened runtime or timestamp: $APP" >&2
  else
    echo "WARNING: DEVELOPER ID SIGNING FAILED; FALLING BACK TO AD-HOC SIGNING. MACOS MAY TREAT EACH REBUILD AS A NEW APP IDENTITY." >&2
    sign_targets_adhoc
    echo "Signed ad-hoc: $APP"
  fi
else
  echo "WARNING: DEVELOPER ID IDENTITY IS UNAVAILABLE; FALLING BACK TO AD-HOC SIGNING. MACOS MAY TREAT EACH REBUILD AS A NEW APP IDENTITY." >&2
  sign_targets_adhoc
  echo "Signed ad-hoc: $APP"
fi

echo "Built: $APP"
