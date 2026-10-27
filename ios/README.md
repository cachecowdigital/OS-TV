# OS TV for iPhone

The same app as the Mac build, sized for a phone: sign in once with your own Xtream Codes
subscription, browse live channels by category, search, favourite, and play — plus the
provider's movie catalogue.

It shares `Sources/IPTVMacCore` with the Mac app — the same client, URL builders and keychain
handling — so a portal that works on one works on the other.

## Status: first version

Working: sign-in with Keychain storage, live catalogue (categories, search, favourites),
movie catalogue, full-screen AVPlayer playback, in-app diagnostics log.

Not yet built for iOS: the TV guide grid, catch-up, series/episodes, parental controls,
picture-in-picture, and a settings window. The Mac app has all of those; the phone build is
deliberately the smaller, reliable core of the same app.

## Build and run

```bash
./ios/build_ios.sh sim      # Debug build for the Simulator
./ios/build_ios.sh device   # Release build for a device (unsigned)
./ios/build_ios.sh ipa      # unsigned .ipa in build/
```

Run it in the Simulator:

```bash
xcrun simctl boot "iPhone 17"
open -a Simulator
xcrun simctl install booted "build/ios/Build/Products/Debug-iphonesimulator/OS TV.app"
xcrun simctl launch booted ca.benyik.ostv
```

For an automated sign-in in a Debug build (no typing on the device), hand the credentials to
the process — they are read only under `#if DEBUG` and never written anywhere except the
Keychain:

```bash
SIMCTL_CHILD_OS_TV_SERVER="http://host:port" \
SIMCTL_CHILD_OS_TV_USER="user" \
SIMCTL_CHILD_OS_TV_PASS="pass" \
xcrun simctl launch --console booted ca.benyik.ostv
```

The app writes every decision it makes to `Documents/ostv.log` (visible in the app under
Account → View diagnostics log, and on the host with
`xcrun simctl get_app_container booted ca.benyik.ostv data`).

## Installing it on a real iPhone

Apple will not run an unsigned build on a normal iPhone, so the route depends on what you have:

- **Apple Developer Program ($99/year)** — archive with your team, upload to App Store
  Connect, and open a public TestFlight link. Anyone you send the link to can install it;
  TestFlight builds expire after 90 days.
- **Free Apple ID** — open the project in Xcode, pick your personal team, plug the phone in
  and Run. It installs and works, but the app stops launching after 7 days until you plug it
  back in.
- **Unsigned .ipa** — only works on a jailbroken device or through a sideloading tool that
  re-signs it with your own Apple ID (AltStore, Sideloadly).

## Notes

- `NSAllowsArbitraryLoads` is set because providers serve plain `http://` portals and HLS
  streams; there is no way to play them under App Transport Security otherwise.
- Nothing is uploaded. There is no server, no account and no telemetry.
- The bundle identifier is `ca.benyik.ostv`.
