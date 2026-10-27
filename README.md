# OS TV

A native macOS IPTV player for your own Xtream Codes subscription, written
clean-room in SwiftUI and branded with the  identity. It plays live TV,
shows a TiviMate-style TV guide, keeps favourites and group lists, and plays
catch-up from the provider's archive.

Built from a written specification only. No code, assets, strings or resources
were taken from TiviMate or any other app; the bundled APK was inspected for
factual questions (does it implement DRM? does it hide your connection?) and
nothing was extracted from it. See **Provenance** below.

## Download

Prebuilt universal builds (Apple Silicon + Intel, macOS 14+) are on the
[Releases](../../releases/latest) page. The build is not notarized, so the first launch is not a
double-click: open the `.dmg`, drag **OS TV** into Applications, then **right-click → Open → Open**
(or *System Settings → Privacy & Security → Open Anyway*). After that it opens normally.

OS TV ships no channels, playlists or keys — you bring your own Xtream Codes subscription.
Credentials are stored only in your own macOS login Keychain; there is no server, account or
telemetry. Only download the DMG from this repository's Releases.

## Contributing

Pull requests and issues are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). **Never paste your
provider host, username or password into an issue, PR or screenshot.**

## Build

```bash
swift build                 # debug
swift test                  # 13 unit tests: XMLTV parsing, timestamps, guide alignment
swift build -c release
./build_app.sh              # -> build/OS TV.app  (ad-hoc signed, icon + assets in place)
open build/OS TV.app
```

Requires Xcode 27 / Swift 6.4. Deployment target macOS 14; built and tested on
macOS 27, Apple Silicon. No third-party dependencies.

> `build_app.sh` aborts on a failed build (`set -euo pipefail`) on purpose. Never
> check its success by filtering its output through `grep` — that hides the failure
> line and leaves the *previous* bundle in place looking like success. Verify the
> artifact instead: `strings build/OS TV.app/Contents/MacOS/IPTVMac | grep <new literal>`.

## Sign in

Enter your provider's server, username and password on the login screen.

- The server field takes what you would type by hand: `host:port`,
  `http://host:port`, `http://host:port/player_api.php`, `.../get.php`, `.../c`.
  It is normalised.
- Leave "Remember me in the Keychain" on and the app auto-signs-in next launch.
- Sign Out deletes the Keychain item.

**Credentials never touch disk.** They live only in the login Keychain as a generic
password under service `IPTVMac`, account `primary`. The app creates the item
itself, which matters: an item created by the `security` CLI is not trusted by the
bundled app and triggers a system prompt asking for your *login keychain* password.

`build_app.sh` signs with an **identifier-based designated requirement**
(`designated => identifier "ca.benyik.jabcorptv"`) instead of the ad-hoc default,
on the theory that the Keychain authorises an app by that requirement and so one
authorisation would survive rebuilds.

**That theory is disproved.** Rebuilt and relaunched to test it, and macOS prompted
again for the login keychain password: the keychain is evidently still binding the
item to a hash of that particular binary. "Always Allow" does not carry over either.

**An item that requires no authorisation was attempted, and it does not work here.**
`CredentialStore.save` creates the item with an access object naming a *nil* trusted
application — the same thing `security add-generic-password -A` does — and the app
re-saves its existing item once to adopt it. `SecItemAdd` accepts the access object
**without error and then ignores it**: a launch that logs
`keychain item re-saved with open access`, followed by a read from a different program,
is still refused and still raises the password prompt. Measured, not assumed.

So the truthful position is:

- **A build you keep using prompts once, not repeatedly.** The dialog offers *Always
  Allow*, and that grant sticks for that binary.
- **Every new build is a stranger again**, because an ad-hoc signature is a hash of that
  binary. This costs *you* nothing in normal use — it costs the developer one prompt per
  rebuild, and only because rebuilding is what changes the identity.
- The way to work on this app without that cost at all is the developer seams described
  under *Testing the guide without a subscription*: `IPTV_GUIDE_FILE` needs no credentials,
  and `IPTV_SERVER`/`IPTV_USER`/`IPTV_PASS` in the environment make the first launch after
  a rebuild import them without touching the keychain.
- `CredentialStore.save(_:accessibleToAnyApplication:)` is kept because it is correct on
  its own terms and costs nothing, but it is documented here as **not** the cure it was
  meant to be.

Two consequences worth knowing:

- If the system ever refuses that access object, `save` falls back to the default rules
  and you are back to one prompt per rebuild — it never fails the save.
- The legacy access API is deprecated in the SDK and the build emits **two
  deprecation warnings** for it, deliberately: it is the only way to store a login
  keychain item that does not ask the per-application question, and a Developer ID
  signature is the only thing that would remove the need for it.

Ad-hoc signing remains not a Developer ID signature: it satisfies no Gatekeeper policy,
so this is for local builds.

For provisioning without typing, a one-shot import runs only when the Keychain is
empty and saves straight into it:

```bash
IPTV_SERVER="http://host:port" IPTV_USER="user" IPTV_PASS="pass" \
  open build/OS TV.app/Contents/MacOS/IPTVMac
```

`IPTV_RESUME_STREAM=<stream_id>` starts that channel as soon as the catalogue
loads. It exists for automated verification and for the resume-on-launch path.

## What is built

**Live TV.** Sidebar — Favourites (live count), Recently watched, All Channels,
then the provider's categories. Channel list with logos, channel numbers, the
current programme and a progress bar, and a star to favourite a channel in place.
Search filters as you type. Playback is `AVPlayerView`, so you get the native
control bar, picture-in-picture and full screen for free.

**TV guide.** A horizontal timeline per channel: sticky channel column, sticky time
ruler, red "now" line, blocks sized by duration, the current programme tinted and
filled to show how far through it you are. The window is 30 minutes back and your
configured hours ahead, rounded to the half hour. The timeline sits in a gutter the
width of the channel column, so the column never swallows the first half hour or the
"now" line the way an overlay-only column does.

The guide is downloaded once to `~/Library/Caches/OS TV/` and reused until the
refresh interval elapses — a full guide runs to tens of megabytes, and `xmltv.php` is
streamed to a file rather than held in memory.

Providers sometimes publish the guide on a different clock, which shows up as a grid
with nothing in it on a guide that is otherwise perfectly good. The app measures that
shift — the correction that puts the most channels on air right now, taking the
smallest correction when several would do — applies it, and says so in the guide
header next to a **Reset shift**. If the window still has nothing in it, the guide
explains itself: it names the span of the data it holds and offers *Align to now*,
±1 h and *EPG settings*, instead of showing a blank grid. Clicking a **future or live**
programme tunes the channel; clicking a **past** programme plays it from catch-up
when the channel carries an archive. Programmes that ended more than three hours
ago are dropped at parse time to bound memory.

**Full screen.** Everything routes through macOS's own full-screen mode, so the
green button, `⌃⌘F` and the in-app **Full Screen** buttons all agree. When the window
is full screen the app renders video and nothing else — no sidebar, no list, no
toolbar, no guide — with a channel strip that fades in on hover. `Esc` exits, as it
does in any macOS app.

**Guide preview.** With the guide open, the channel you are watching floats in the
top-right corner as a live preview, the way TiviMate does it, so you can keep
watching while you browse. It is the *same* `AVPlayer`, so it never opens a second
stream and cannot breach your connection limit. Buttons on it go full screen or hide
it; it is re-enabled in Settings › EPG.

**Catch-up.** Channels advertising `tv_archive` show the archive length. Playing a
past programme builds
`{base}/timeshift/{user}/{pass}/{minutes}/{yyyy-MM-dd:HH-mm}/{stream_id}.m3u8`
(the start time in **UTC** — the thing everybody gets wrong), and the player shows a
`CATCH-UP` badge with a **Back to Live** button.

**Settings** (⌘,), grouped as TiviMate groups them — Appearance, Playback, EPG,
Channels, Parental, Account, Backup, About. Every switch does something:

| Setting | Effect |
|---|---|
| Appearance / Accent | Dark, light or system; orange or teal accent. Sets the AppKit appearance too, so AppKit-backed controls match. |
| Compact rows, channel numbers, logos, catch-up badge | What each channel row shows. |
| Sort by number / name | Channel ordering. |
| Preferred format (HLS / TS) | Which stream URL shape is built. |
| Stop the previous stream before starting a new one | Zap behaviour; respects your provider's connection limit. |
| Resume the last channel on launch | Tunes your most recently watched channel at startup. |
| VLC path | Application used by the **Open in VLC** fallback. |
| Guide hours ahead / minutes back | The guide window. |
| Guide refresh interval | How often the guide is re-downloaded. |
| Guide time offset | Shifts every programme by ±N minutes, for providers that publish the guide in the wrong timezone. |
| Show progress in the current programme | The fill inside the live block. |
| Show a live preview window over the guide | The floating corner preview. |
| Auto-align the guide with the current time | Measures and corrects a provider whose guide is published on another clock. |
| Hidden categories | Unticked categories disappear from the sidebar and the guide. |
| Parental controls + PIN | Categories matching your keywords are hidden and gated behind a PIN for the session; optionally gate the Settings window itself. |
| Backup | Export/import settings, favourites and groups as JSON, and reset to defaults. Credentials are never included. |
| Account / diagnostics | Provider status, expiry, connections used, panel version, guide status, and a live playback probe with HTTP code and latency. |

## Brand

Sampled from your own vector logo, not guessed: brand **orange `#FE5D1E`** and
**teal `#045E6E`** are 97%+ of the ink in `JABCORP-logo-vector.svg`. The dark
surface (`#0E1115`) comes from the  website's `--background`. The teal used
on dark surfaces is the brand teal **lifted in lightness only** (hue preserved) so
it stays legible on near-black.

| Asset | Purpose |
|---|---|
| `Resources/AppIcon.icns` | App icon: the chip-with-brain mark on a brand-orange tile, on Apple's icon grid. |
| `Resources/LockupOnDark.png` | Header lockup (mark + wordmark + tagline) for the login screen and About. |
| `Resources/BrandMark.png` | The mark alone, for the sidebar strip. |
| `Resources/Logo-transparent.png` | The mark and wordmark with the body knocked out, recoloured for dark surfaces. |

The logo lives in `~/Desktop/ Logo/`; assets are regenerated from it and
committed here so builds need no external path. Note the `-on-dark` SVG variant
they ship has its background **baked in** (0% transparent pixels), so it cannot be
composited onto a different surface without a visible seam — the dark-surface
lockup here is built from the plain vector instead.

## Known limitations

**DRM-protected streams cannot be played, on any native macOS app.** This is a
platform wall, not a missing feature. Android plays Widevine because each *device*
ships a CDM; Apple ships FairPlay, and Google licenses no Widevine CDM for macOS.
PlayReady is unavailable too. Nothing here attempts to bypass DRM. See the DRM
section of `docs/PROMPT-v2.md`. *Detect-and-report (recognising a DRM-protected
stream and saying so plainly rather than showing a generic failure) is still to
build.*

**Small icon sizes.** The mark is correct at 128 and 256 px — the sizes macOS
actually uses for the Dock and the app switcher. At 32 and 16 px the fine circuit
detail collapses into a small white chip. Fixing that properly needs a
hand-simplified glyph for those sizes, not a scaled-down icon.

**TS-only providers.** AVPlayer plays HLS well but cannot play raw MPEG-TS over
HTTP. Portals advertising `m3u8, ts, rtmp` are fine as long as they serve HLS;
otherwise use **Open in VLC**, or wait for the libVLC engine.

**The guide depends on the provider.** It comes from `xmltv.php`. A guide that is
missing, stale, or drawn on the wrong clock is reported specifically — with the span
of the data actually held, and a one-click correction — rather than being shown as an
empty grid. The now/next panel falls back to the short-EPG endpoint for the channel
you are watching, and channels the guide does not cover show no now/next in the list.

**Guide alignment is a measurement, not a certainty.** Only the *relative* shift is
knowable: a guide can always be slid so that something is on air. The app therefore
takes the smallest correction that puts the most channels on air right now, refuses to
act on fewer than five channels of evidence, and always shows what it did. It is
unit-tested (`Tests/IPTVMacCoreTests/GuideAlignmentTests.swift`) rather than eyeballed.

**Portal drift.** Reseller portals move or die without notice, and some now publish
their portal URLs only in a private Discord. A dead portal and a wrong password look
different in this app's errors on purpose: a parked domain answering through an
administrative proxy is reported as "answered, but not like an Xtream Codes portal",
not as a JSON error.

**Provider padding.** Real portals ship blank placeholder rows (no name, no EPG id).
These are hidden and counted in the status line rather than shown as channels. The
a typical portal returns thousands of rows, a small share of them blank.

## Provenance and anti-goals

- **Clean-room.** Written from a specification. Nothing was decompiled, and no
  code, asset, string or resource was taken from any third-party app.
- **No licence circumvention.** TiviMate's Premium features are simply features
  here, because this is our own app.
- **No bundled content.** The app ships with no playlists, channels, credentials or
  provider URLs.
- **Nothing hides your connection from the provider.** There is no proxy, VPN,
  tunnel or spoofing feature, and there will not be one. Requests carry a plain
  `IPTVMac/1.0` user-agent.
- **Credentials are never logged or printed.** Password fields are secure, the
  probe redacts, and the diagnostics panel reports the portal *host* only.


## Layout

```
Sources/IPTVMacCore/   Flex.swift          lenient scalar decoding for inconsistent portals
                       Models.swift        Account, ChannelCategory, Channel, Programme
                       XtreamClient.swift  URL normalisation, API calls, stream URLs
                       XMLTVParser.swift   streaming SAX guide parser, never builds a DOM
                       GuideAlignment.swift measures a provider's guide clock error
                       Keychain.swift      the only place credentials live
Sources/IPTVMac/       App.swift           app, Settings scene, PIN-gated settings window
                       AppModel.swift      session, catalogue, EPG, playback, parental
                       Brand.swift         brand colours and asset loading
                       Settings.swift      all settings, Codable, one persisted value
                       Favourites.swift    favourites, recents, group lists
                       Views.swift         login, sidebar, channel list, player
                       GuideView.swift     the TV guide grid
                       SettingsView.swift  the settings window
                       Resources/          icon and brand assets, copied in by build_app.sh
Sources/iptvprobe/     main.swift          acceptance harness
Tests/IPTVMacCoreTests XMLTV parser and guide alignment unit tests
docs/PROMPT-v2.md      the build spec, DRM section included
```

## Notes for whoever works on this next

- Do not name a type `Category`. It collides with the ObjC runtime's `Category`
  struct as soon as AppKit or AVKit is imported. It is `ChannelCategory` here.
- Do not start playback from inside a `List` selection binding. It is a reentrant
  operation in `NSTableView`'s delegate — a warning today, an assert later. Defer
  one main-actor turn.
- **The channel list no longer filters per render pass.** `AppModel.visibleChannels`
  used to be a computed property, so `ForEach` got a freshly-filtered array of
  thousands of channels on every render while the table was diffing — the cause of a reentrancy
  warning on first population, and a real cost. The filtered array is now cached in
  `AppModel.filteredChannels` and recomputed only when the query, category,
  favourites, hidden categories or parental state change.
- **Watch out for string interpolation when generating Swift from another language.**
  A `\#(...)` that should have been `\(...)` compiles into a call to
  `replacingOccurrences` and silently produces the wrong text. Grep generated Swift
  for `replacingOccurrences(of: "` before trusting it.
- Verify the *artifact*, not the build's exit code. A build system can report
  success while shipping a stale binary; after a corrupted build database
  (`disk I/O error` on `.build/.../build.db`) that is exactly what happens. Grep the
  built binary for your new literal, and `rm -rf .build/out` when in doubt.
- Never add anything that hides the user's connection from the provider.

## License

Source code is released under the [MIT License](LICENSE). The Jabcorp name, logo and OS TV
brand artwork (`Sources/IPTVMac/Resources/`) are not covered by that licence — forks should
swap in their own branding.

Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).
