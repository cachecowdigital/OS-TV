# Contributing to OS TV

Thanks for wanting to make this better. A few things about this codebase are unusual, and they
matter more than style preferences.

## Build and test

```bash
swift build          # debug
swift test           # 58 unit tests, expect all green
./build_app.sh       # -> build/OS TV.app (ad-hoc signed, assets in place)
open "build/OS TV.app"
```

Requires a current Xcode (Swift 6.0 or later; the package declares
`// swift-tools-version: 6.0`, platform floor macOS 13.0). No third-party dependencies —
**open an issue before adding one**, the zero-dependency property is deliberate.

`build_app.sh` aborts on a failed build with `set -euo pipefail`. Never check its success by
grepping its output; a grep that finds nothing still exits 0 and leaves the *previous* bundle in
place looking like a fresh success. Verify the artifact:

```bash
strings "build/OS TV.app/Contents/MacOS/IPTVMac" | grep <a-literal-you-just-added>
```

## Ground rules that are not negotiable

1. **Clean room.** This app was written from a written specification. No code, assets, strings,
   XIBs or resources may be copied or decompiled from TiviMate or any other IPTV player. Do not
   paste anything you obtained by unpacking another app. If a change needs reference behaviour,
   describe the behaviour in words and implement it independently.
2. **Credentials never enter the repo.** Provider logins live in the macOS Keychain (service
   `IPTVMac`). No `.env`, no test fixtures with a real host/user/pass, no screenshots showing a
   password. `*.credentials` and `.env` are gitignored — keep it that way.
3. **The bundle id `ca.benyik.jabcorptv` is frozen.** It is the identity the Keychain item and
   `~/Library/Application Support` state are bound to. Changing it silently wipes favourites,
   settings, parental PIN and saved login for anyone already using the app. If a change genuinely
   requires a new id, it must ship with a migration — discuss first.
4. **Signing and release packaging stay with the maintainer.** Don't touch `build_dmg.sh`'s
   signing behaviour, don't commit build artifacts (`build/`, `*.app`, `.build*` are ignored), and
   don't publish builds from your own machine under this app's name.

## What a good change looks like

- **Put logic in `IPTVMacCore`, not in views.** Parsing, normalisation, EPG alignment, provider
  identity, playlist handling all live there and are unit tested. A model/parser change without a
  test will be sent back.
- **UI changes: say how you verified them.** A screenshot, or the relevant log line. "Looks fixed"
  is not verification in this project — a previous run of "fixed, unverified" commits each needed a
  second pass. If you can't verify it, say so in the PR rather than claiming it works.
- **One concern per PR.** Small and reviewable beats complete and unreadable.
- **Commit subject in the imperative**, and explain *why* in the body. Repository history is the
  project's memory.
- **Don't reformat unrelated files.** A whitespace-only diff buries the real change.

## Submitting

1. Branch off `main` (`git checkout -b fix/guide-scroll`), never push to `main` directly.
2. Keep `swift build && swift test` green locally before you open the PR.
3. Open a PR describing: what was broken, what you changed, how you verified it.
4. CI runs `swift build` and `swift test` on every push and PR. A red run is not ready for review.

## Reporting a bug

Include: macOS version, whether Apple Silicon or Intel, what you did, what you expected, what
happened, and any relevant line from Console (filter by process `IPTVMac`). **Never include your
provider host, username or password** in a report or screenshot.
