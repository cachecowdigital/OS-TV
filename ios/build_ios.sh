#!/bin/bash
# Build the iOS app.
#
#   ./ios/build_ios.sh sim       # Debug build for the Simulator (no signing needed)
#   ./ios/build_ios.sh device    # Release build for a real iPhone, unsigned
#   ./ios/build_ios.sh ipa       # unsigned .ipa in build/ — installable only on a jailbroken
#                                # device or through a sideloading tool; see ios/README.md
#
# A signed build (the only kind a normal iPhone will run) needs a development team:
#   xcodebuild -project ios/OS-TV-iOS.xcodeproj -scheme "OS TV" -configuration Release \
#     -destination 'generic/platform=iOS' -archivePath build/OS-TV.xcarchive \
#     DEVELOPMENT_TEAM=YOURTEAMID archive
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="ios/OS-TV-iOS.xcodeproj"
SCHEME="OS TV"
MODE="${1:-sim}"

case "$MODE" in
  sim)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/ios build
    echo "App: build/ios/Build/Products/Debug-iphonesimulator/OS TV.app"
    ;;
  device)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath build/ios \
      CODE_SIGNING_ALLOWED=NO build
    echo "App: build/ios/Build/Products/Release-iphoneos/OS TV.app"
    ;;
  ipa)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath build/ios \
      CODE_SIGNING_ALLOWED=NO build
    APP="build/ios/Build/Products/Release-iphoneos/OS TV.app"
    rm -rf build/ipa && mkdir -p build/ipa/Payload
    cp -R "$APP" build/ipa/Payload/
    (cd build/ipa && zip -qry "../OS-TV-ios-unsigned.ipa" Payload)
    echo "IPA: build/OS-TV-ios-unsigned.ipa (unsigned)"
    ;;
  *)
    echo "usage: $0 [sim|device|ipa]" >&2
    exit 2
    ;;
esac
