#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO_ROOT/build/Ajman.app"
SIGNING_IDENTITY="Developer ID Application: Kazys Varnelis (PHCL25Z99X)"
SIGNING_SHA1="EECF633E96C251FCD3B4FD76BF9D62DE648826A7"

# Check the one machine-wide profile before replacing any existing artifact.
xcrun notarytool history --keychain-profile notary >/dev/null

"$SCRIPT_DIR/build-app.sh"

if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_SHA1"; then
  echo "Required Developer ID signing identity is unavailable: $SIGNING_IDENTITY" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP"
APP_SIGNATURE="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1)"
HOOK="$APP/Contents/MacOS/ajman-hook"
HOOK_SIGNATURE="$(/usr/bin/codesign -d --verbose=4 "$HOOK" 2>&1)"
if ! grep -Fq "Authority=$SIGNING_IDENTITY" <<<"$APP_SIGNATURE"; then
  echo "App is not signed with the required Developer ID identity." >&2
  exit 1
fi
for SIGNED_COMPONENT in "$APP_SIGNATURE" "$HOOK_SIGNATURE"; do
  if ! grep -Fq "Authority=$SIGNING_IDENTITY" <<<"$SIGNED_COMPONENT"; then
    echo "An app executable is not signed with the required Developer ID identity." >&2
    exit 1
  fi
  if ! grep -Eq 'flags=.*\(runtime\)' <<<"$SIGNED_COMPONENT"; then
    echo "An app executable does not enable the hardened runtime." >&2
    exit 1
  fi
  if ! grep -Eq '^Timestamp=' <<<"$SIGNED_COMPONENT"; then
    echo "An app executable does not contain a secure timestamp." >&2
    exit 1
  fi
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLUME_NAME="Ajman $VERSION"
OUTPUT="$REPO_ROOT/build/Ajman-$VERSION.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ajman-dmg.XXXXXX")"
APP_ZIP="$WORK_DIR/Ajman.zip"
STAGING="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/Ajman-rw.dmg"
FINAL_DMG="$WORK_DIR/Ajman-$VERSION.dmg"
MOUNT_POINT="$WORK_DIR/mount"
MOUNT_DEVICE=""
LAYOUT_TIMEOUT_SECONDS=10

cleanup() {
  if [[ -n "$MOUNT_DEVICE" ]]; then
    hdiutil detach "$MOUNT_DEVICE" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT_DEVICE" -force -quiet >/dev/null 2>&1 || true
  elif mount | grep -Fq " on $MOUNT_POINT "; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Apple notarizes the ZIP submission, then the ticket is stapled to the app.
ditto -c -k --keepParent "$APP" "$APP_ZIP"
"$SCRIPT_DIR/notarize.sh" "$APP_ZIP" "$APP"

# Only after the app has its ticket do we copy it into the disk image.
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Ajman.app"
ln -s /Applications "$STAGING/Applications"

if [[ ! -d "$STAGING/Ajman.app" ]]; then
  echo "Staging failed: Ajman.app is missing." >&2
  exit 1
fi
if [[ ! -L "$STAGING/Applications" || "$(readlink "$STAGING/Applications")" != "/Applications" ]]; then
  echo "Staging failed: Applications is not a symlink to /Applications." >&2
  exit 1
fi
xcrun stapler validate "$STAGING/Ajman.app"

MAGICK="$(command -v magick || command -v convert || true)"
if [[ -z "$MAGICK" ]]; then
  echo "WARNING: ImageMagick is unavailable; continuing without a DMG background." >&2
else
  mkdir -p "$STAGING/.background"
  if ! "$MAGICK" -size 720x460 canvas:'#e9edf2' \
    -fill '#111827' -font Helvetica-Bold -pointsize 25 -gravity north \
    -annotate +0+34 'Drag Ajman to Applications' \
    -fill '#4b5563' -font Helvetica -pointsize 15 \
    -annotate +0+72 'Then open Ajman from your Applications folder' \
    -stroke '#596579' -strokewidth 10 -fill none \
    -draw 'bezier 280,235 350,205 405,205 470,235' \
    -stroke none -fill '#596579' \
    -draw 'polygon 466,211 505,239 462,258' \
    -fill '#6b7280' -pointsize 13 -gravity south \
    -annotate +0+28 'macOS 14 or later' \
    "$STAGING/.background/background.png"; then
    echo "WARNING: ImageMagick could not create the DMG background; continuing without it." >&2
    rm -rf "$STAGING/.background"
  fi
fi

hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLUME_NAME" -fs HFS+ \
  -format UDRW -ov "$RW_DMG"

mkdir -p "$MOUNT_POINT"
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT_POINT" "$RW_DMG")"
MOUNT_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
if [[ -z "$MOUNT_DEVICE" || ! -d "$MOUNT_POINT" ]]; then
  echo "Could not locate the mounted DMG device or volume." >&2
  exit 1
fi

layout_dmg_window() {
  osascript <<APPLESCRIPT
with timeout of $LAYOUT_TIMEOUT_SECONDS seconds
  tell application "Finder"
    tell disk "$VOLUME_NAME"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      set bounds of container window to {120, 120, 840, 580}
      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 112
      set text size of theViewOptions to 14
      if exists file ".background:background.png" then
        set background picture of theViewOptions to file ".background:background.png"
      end if
      set position of item "Ajman.app" of container window to {175, 235}
      set position of item "Applications" of container window to {545, 235}
      update without registering applications
      delay 2
      close
    end tell
  end tell
end timeout
APPLESCRIPT
}

LAYOUT_SUCCEEDED=false
for LAYOUT_ATTEMPT in 1 2 3; do
  if LAYOUT_OUTPUT="$(layout_dmg_window 2>&1)"; then
    LAYOUT_SUCCEEDED=true
    echo "Finder DMG window layout succeeded on attempt $LAYOUT_ATTEMPT."
    break
  fi
  echo "WARNING: Finder DMG window layout attempt $LAYOUT_ATTEMPT failed; continuing with a functional DMG without custom icon arrangement or background." >&2
  [[ -z "$LAYOUT_OUTPUT" ]] || printf '%s\n' "$LAYOUT_OUTPUT" >&2
  if [[ $LAYOUT_ATTEMPT -lt 3 ]]; then
    sleep 2
  fi
done
if [[ "$LAYOUT_SUCCEEDED" != true ]]; then
  echo "WARNING: Giving up on Finder DMG window layout after 3 attempts; continuing the build." >&2
fi

sync
hdiutil detach "$MOUNT_DEVICE" -quiet
MOUNT_DEVICE=""

hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG"

codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$FINAL_DMG"
codesign --verify --strict --verbose=4 "$FINAL_DMG"
echo "Signed DMG with Developer ID and secure timestamp."

"$SCRIPT_DIR/notarize.sh" "$FINAL_DMG" "$FINAL_DMG"

xcrun stapler validate "$APP"
spctl -a -vv "$APP"
spctl -a -vv -t install "$FINAL_DMG"

# Publish only the fully signed, notarized, stapled, and Gatekeeper-accepted image.
mv -f "$FINAL_DMG" "$OUTPUT"
xcrun stapler validate "$OUTPUT"
spctl -a -vv -t install "$OUTPUT"

echo "Created: $OUTPUT"
