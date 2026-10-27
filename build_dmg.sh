#!/bin/bash
# Packages OS TV.app into a distributable .dmg: double-click to mount, drag to Applications,
# the standard macOS install pattern. Runs build_app.sh first so the DMG always holds a fresh
# universal build, not whatever happened to be sitting in build/ already.
#
# NOTE ON GATEKEEPER: this app is ad-hoc signed (codesign --sign -), not signed with a Developer
# ID and notarized. Ad-hoc signing is enough for the app to run ON THIS MACHINE and satisfies
# LaunchServices' architecture/minimum-OS checks, but macOS marks anything downloaded from the
# internet with a quarantine flag, and Gatekeeper refuses to open a quarantined app that isn't
# Developer-ID-signed-and-notarized — "<App> can't be opened because Apple cannot check it for
# malicious software," with no "Open Anyway" button visible by default. A recipient can still
# open it (right-click → Open, or System Settings → Privacy & Security → "Open Anyway" after the
# first blocked attempt, or `xattr -dr com.apple.quarantine "OS TV.app"` in Terminal) but it is
# NOT the double-click-and-go experience "installable like any other Mac app" implies. See
# The maintainer note — a Developer ID certificate + notarization is the one gate this script cannot
# close on its own; it needs the owner's own paid Apple Developer Program membership.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="OS TV"
APP_PATH="build/${APP_NAME}.app"

echo "==> building ${APP_NAME}.app (build_app.sh)"
./build_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_NAME="OS-TV-${VERSION}.dmg"
DMG_PATH="build/${DMG_NAME}"
VOL_NAME="${APP_NAME} ${VERSION}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging DMG contents"
cp -R "$APP_PATH" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
cp "How to Open.txt" "$STAGE/How to Open.txt"
cp "assets/OS TV Feature Guide.png" "$STAGE/OS TV Feature Guide.png"

rm -f "$DMG_PATH"
echo "==> creating $DMG_NAME"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "==> verifying mount"
MOUNT_OUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
MOUNT_POINT="$(echo "$MOUNT_OUT" | tail -1 | awk -F'\t' '{print $NF}')"
if [ ! -d "$MOUNT_POINT/${APP_NAME}.app" ] || [ ! -L "$MOUNT_POINT/Applications" ] \
    || [ ! -f "$MOUNT_POINT/How to Open.txt" ] || [ ! -f "$MOUNT_POINT/OS TV Feature Guide.png" ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    echo "!! mounted DMG is missing the app, the Applications shortcut, the instructions, or the feature guide" >&2
    exit 1
fi
hdiutil detach "$MOUNT_POINT" >/dev/null

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
echo "==> done: $(pwd)/$DMG_PATH ($SIZE)"
echo "    Gatekeeper note: ad-hoc signed only, not notarized — see this script's header comment."
