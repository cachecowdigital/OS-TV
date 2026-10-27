#!/bin/bash
# Builds OS TV.app — a real double-clickable macOS app bundle around the SwiftPM binary.
# NOTE: never filter this script's output through grep when checking success; a hidden
# failure line leaves the PREVIOUS bundle in place and still reads like success.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
APP_NAME="OS TV"
EXECUTABLE="IPTVMac"
BUNDLE_ID="ca.benyik.jabcorptv"
VERSION="0.2.2"
BUILD="$(date +%Y%m%d%H%M)"
BUILD_STARTED="$(date +%s)"

# Ventura-era Macs are frequently Intel, so a macOS 13 claim needs an x86_64 slice beside the
# arm64 one. The two slices are built in SEPARATE invocations and joined with lipo, because
# asking one invocation for both architectures intermittently kills Xcode's build service. Its
# signature is "accessing build database ... disk I/O error" followed by a "Build complete"
# that copies a stale binary — a silent failure that reads exactly like success, and did.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# The bundle build keeps its own scratch directory. Sharing .build with `swift build` (debug) and
# `swift test` is what corrupted it repeatedly here — interleaved runs leave a partial
# intermediates tree, and the next build fails on a missing dependency file or an unreadable
# build database. Separate scratch paths make that impossible rather than unlikely.
SCRATCH=".build-release"
ARCH_FLAGS=(--scratch-path "$SCRATCH")

build_slice() {
    local arch="$1" dest="$2" bin log status attempt=1
    log="$STAGE/$arch-build.log"

    while : ; do
        echo "==> swift build -c $CONFIG --arch $arch${attempt:+ (attempt $attempt)}"
        set +e
        swift build -c "$CONFIG" --arch "$arch" "${ARCH_FLAGS[@]}" >"$log" 2>&1
        status=$?
        set -e

        if [ "$status" -eq 0 ] && ! grep -qE "error: |disk I/O error|internal inconsistency" "$log"; then
            break
        fi

        # Xcode's build service dies intermittently on this machine -- "accessing build database
        # ... disk I/O error", or a missing libtool dependency file after an interrupted step --
        # and the compiler still prints "Build complete!" with a zero exit status. Clearing the
        # intermediates and retrying once has been reliable; a second failure is reported and
        # stops the run, because assembling a stale bundle that reads as success is the failure
        # mode this script has actually produced.
        if [ "$attempt" -ge 2 ]; then
            echo "!! the $arch build reported failure (attempt $attempt):" >&2
            grep -E "error: |internal inconsistency" "$log" | head -4 >&2
            exit 1
        fi
        echo "   build service error — clearing intermediates and retrying once" >&2
        rm -rf "$SCRATCH/out"
        attempt=2
    done

    bin="$(swift build -c "$CONFIG" --arch "$arch" "${ARCH_FLAGS[@]}" --show-bin-path)/$EXECUTABLE"
    if [ ! -f "$bin" ]; then
        echo "!! no binary for $arch at $bin" >&2
        exit 1
    fi
    cp "$bin" "$dest"
}

build_slice arm64 "$STAGE/$EXECUTABLE-arm64"
build_slice x86_64 "$STAGE/$EXECUTABLE-x86_64"

OUT="build/${APP_NAME}.app"

echo "==> assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "==> lipo arm64 + x86_64"
lipo -create "$STAGE/$EXECUTABLE-arm64" "$STAGE/$EXECUTABLE-x86_64" \
     -output "$OUT/Contents/MacOS/$EXECUTABLE"

SLICES="$(lipo -archs "$OUT/Contents/MacOS/$EXECUTABLE")"
for arch in arm64 x86_64; do
    if ! echo "$SLICES" | tr ' ' '\n' | grep -qx "$arch"; then
        echo "!! the assembled binary has no $arch slice (has: $SLICES)" >&2
        exit 1
    fi
done
echo "    slices: $SLICES"

# Strip the symbol table BEFORE signing (stripping invalidates a signature). The unstripped
# binary carries this machine's build paths — "/Users/<account>/Desktop/PROJECTS-GITHUB/IPTVMac/
# Sources/..." — in its symtab, which hands every downloader the owner's account name and folder
# layout. `-S` removes debug symbols only; `-x` is deliberately not used, since it also drops local
# symbols the Swift runtime can walk.
echo "==> strip build paths"
strip -S "$OUT/Contents/MacOS/$EXECUTABLE"
if grep -aq "$HOME/" "$OUT/Contents/MacOS/$EXECUTABLE"; then
    echo "!! the binary still contains $HOME paths" >&2
    exit 1
fi
echo "    clean: no build-machine paths"

# brand assets live in the repo beside the sources and are copied in here
for asset in AppIcon.icns BrandMark.png BrandLockup.png JabcorpLogo.png ; do
    if [ -f "Sources/IPTVMac/Resources/$asset" ]; then
        cp "Sources/IPTVMac/Resources/$asset" "$OUT/Contents/Resources/"
    fi
done

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <!-- Must match Package.swift's platform. This key is what LaunchServices enforces:
         code compiled for 13 still refuses to open on 13 if this says 14. -->
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Clean-room Xtream Codes player</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Most IPTV portals serve plain http:// and per-session token URLs. -->
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
# The Keychain authorises an app by its designated requirement. Ad-hoc signing stores
# a hash-based requirement by default, so every rebuild looks like a different app and
# re-prompts for the login keychain password. Keying the requirement on the bundle
# identifier instead keeps the authorisation valid across rebuilds.
# The leading "=" marks this as a requirement string rather than a filename.
REQUIREMENT='=designated => identifier "ca.benyik.jabcorptv"'
codesign --force --sign - --timestamp=none --requirements "$REQUIREMENT" "$OUT" >/dev/null 2>&1 \
  || codesign --force --sign - --timestamp=none "$OUT" >/dev/null 2>&1 \
  || echo "   (codesign skipped)"
echo "    requirement: $(codesign -d -r- "$OUT" 2>&1 | tail -1)"

echo "==> done: $(pwd)/$OUT"
echo "    open \"$(pwd)/$OUT\""
