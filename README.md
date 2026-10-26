# OS TV

Download page for **OS TV** — a native macOS IPTV player for your own Xtream Codes subscription. The source is kept in a private repository; only the built app is published here.

**➡️ Grab the latest build from [Releases](../../releases/latest).**

## What it does

Live TV, a TiviMate-style TV guide, favourites and groups, and catch-up from your provider's archive. Written clean-room in SwiftUI from a written specification — nothing taken from TiviMate or any other app. The app ships no channels, playlists or keys; you bring your own subscription.

## Requirements

- macOS 13.0 or later
- Apple Silicon or Intel (universal build)

## Installing — please read, first launch is not a double-click

This build is not notarized by Apple, so macOS refuses the first open with *"Apple cannot check it for malicious software."* That is expected and it is a one-time step:

1. Open the `.dmg` and drag **OS TV** into your Applications folder.
2. **Right-click** (or Control-click) **OS TV** → **Open** → click **Open** again to confirm.
3. If step 2 shows no Open option: **System Settings → Privacy & Security → Security → "Open Anyway"** next to OS TV.

After that, it opens with a normal double-click. The same instructions are inside the DMG as `How to Open.txt`, next to a feature guide image.

## Signing in

Enter your provider's server, username and password on the login screen. Credentials are stored only in your own macOS login Keychain and are never uploaded — there is no server, no account, no telemetry.

## Security note

Only download the DMG from this repository's Releases. If someone hands you an OS TV build from anywhere else, it is not from us.
