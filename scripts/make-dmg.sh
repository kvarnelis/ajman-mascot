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
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# Apple notarizes the ZIP submission, then the ticket is stapled to the app.
ditto -c -k --keepParent "$APP" "$APP_ZIP"
"$SCRIPT_DIR/notarize.sh" "$APP_ZIP" "$APP"

# Only after the app has its ticket do we copy it into the disk image.
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/Ajman.app"
ln -s /Applications "$STAGING/Applications"

MAGICK="$(command -v magick || command -v convert || true)"
if [[ -z "$MAGICK" ]]; then
  echo "ImageMagick is required to draw the DMG background." >&2
  exit 1
fi

"$MAGICK" -size 720x460 canvas:'#e9edf2' \
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
  "$STAGING/.background/background.png"

hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLUME_NAME" -fs HFS+ \
  -format UDRW -ov "$RW_DMG"

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "Could not locate the mounted DMG volume." >&2
  exit 1
fi

osascript <<APPLESCRIPT
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
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "Ajman.app" of container window to {175, 235}
    set position of item "Applications" of container window to {545, 235}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

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
