# Prompt: Build a TiviMate-style native macOS IPTV player (clean-room)

## Role and goal

You are a senior macOS engineer. Build a native macOS IPTV player in SwiftUI whose
feature set and workflow resemble TiviMate on Android: a fast channel list, a
TV-guide grid, favourites, catch-up, multi-playlist support. It plays the user's
own paid IPTV subscription over the Xtream Codes API.

## Status (kept current)

Shipped as **OS TV**, branded with the  identity (brand orange
`#FE5D1E`, brand teal `#045E6E`, dark surface `#0E1115`, all sampled from the
supplied vector logo).

**Built and working**: login and Keychain session; sidebar with Favourites,
Recently watched and provider categories; channel list with logos, numbers,
current programme, progress bar and inline favourite star; search; player pane with
now/next and description; TV guide (sticky channel column, sticky ruler, now line,
duration-sized blocks, click to watch live or play catch-up); catch-up with a Back
to Live control; favourites and group lists persisted; hidden categories; sort by
number or name; the full settings window (appearance, playback, EPG, channels,
parental, account diagnostics, JSON backup); parental PIN gating categories and
optionally the Settings window; Open in VLC fallback; **full screen** driven by
macOS's own full-screen state so every route into it agrees, rendering video only;
a **TiviMate-style floating guide preview** sharing the one player; a **cached
guide** reused until the refresh interval; and **guide clock alignment** — measuring
and correcting a provider that publishes its guide on another clock, with the shift
disclosed in the guide header and a Reset.

**Not built**: DRM detect-and-report (the section below is still the spec for it);
multiple provider profiles; recording; guide reminders; multiview; VOD and series;
M3U/XMLTV as an alternate source; audio/subtitle and aspect-ratio controls; keyboard
navigation and last-channel recall via a key; libVLC engine; a hand-simplified icon
glyph for 32/16 px.

**Verified**: `iptvprobe` 17/17 against the live reference portal, twice (env
credentials and Keychain); 13/13 unit tests (XMLTV parsing and guide alignment); GUI
screenshot runs; the guide's data path proven end to end (channel column rendered
from real guide data, and the floating preview showing live video). See the README's
verification table for the specifics.

**Not yet verified** — do not claim these: the guide *grid* rendering real provider
data after the alignment fix; guide scrolling after the sticky-layer sign correction;
catch-up playback of a real archive stream; favourites surviving a relaunch; the DRM
detect-and-report path.

## Hard constraints (read first)

**Clean-room only.** Do NOT decompile, disassemble, extract, or copy code, assets,
strings, or resources from `tivimate.apk` or any other proprietary app. Do not run
apktool, jadx, dexdump, smali, or any similar tool against it. TiviMate is a
feature reference from public knowledge of what an IPTV player does; every line of
this app is written from scratch. (Inspection for factual questions - "does this
APK contain a DRM implementation?" - is fine. Lifting anything into the build is not.)

**No licence circumvention.** Do not recreate, bypass, or unlock TiviMate's Premium
licensing. Features that are premium in TiviMate (guide, catch-up, multi-playlist,
favourite groups) are simply ordinary features here, because this is our own app.

**No bundled content.** The app ships with no playlists, channels, credentials, or
provider URLs. The user enters their own provider's server, username and password.

**Never log or print passwords.** Credentials live only in the macOS Keychain. The
only credential-bearing string ever printed is a redacted `user@host`.

**Anti-goal: nothing may hide the user's connection from the provider.** No VPN,
proxy, tunnel, traffic-masking, or "connection protection" feature of any kind.
TiviMate has no such feature and neither does this app. Traffic goes straight to
the portal. If a request to add one appears, it is out of scope.

## Platform and stack

- macOS 14+ deployment target, built and tested on **macOS 27 with Xcode 27 /
  Apple Swift 6.4**; Swift language mode 5; Apple Silicon.
- SwiftUI, `@Observable` (Observation), AVKit/AVFoundation for playback.
- Swift Package Manager. Three targets: a `Core` library, the app executable, and a
  `probe` executable used as the verification harness.
- `build_app.sh` builds a release binary and wraps it in `OS TV.app` with an
  `Info.plist` carrying `NSAllowsArbitraryLoads` (many portals serve plain http://
  and per-session token URLs) plus ad-hoc codesign.
- No third-party dependencies in v1. libVLC / MPVKit arrive later behind a
  `PlayerEngine` protocol (see Playback).

## Xtream Codes API (the data source)

Base URL is normalised from user input: add `http://` if missing, strip trailing
`/`, strip a trailing `/player_api.php`, `/get.php`, `/xmltv.php`, or `/c`.

| Purpose | Request |
|---|---|
| Login / account info | `GET {base}/player_api.php?username=U&password=P` -> `user_info {auth, status, exp_date (unix), max_connections, active_cons}` and `server_info` |
| Live categories | `...&action=get_live_categories` -> `[{category_id, category_name}]` |
| Live channels | `...&action=get_live_streams` -> `[{num, name, stream_id, stream_icon, epg_channel_id, category_id, tv_archive, tv_archive_duration}]` |
| Short EPG (per channel) | `...&action=get_short_epg&stream_id=ID&limit=N` -> `epg_listings[]` with base64 title / description and `start_timestamp` / `stop_timestamp` |
| Full guide | `GET {base}/xmltv.php?username=U&password=P` -> XMLTV (can be tens of MB) |
| Live stream | `{base}/live/U/P/{stream_id}.m3u8` (HLS, preferred) or `.ts` |
| Catch-up | `{base}/timeshift/U/P/{minutes}/{YYYY-MM-DD:HH-mm}/{stream_id}.m3u8` (start time in **UTC**; `.ts` also valid) |

Implementation rules:

- Portals return numbers as strings or ints, fields may be null, and some rows are
  junk. Decode leniently through a single wrapper type rather than a concrete Swift
  type per field. One odd field must never take down a 9,000-row catalogue.
- Set a generic User-Agent (`IPTVMac/1.0`). Timeout 30 s. Treat non-2xx as errors
  with readable messages. `auth == 0` means login rejected.
- **A portal that is not a portal.** Portals go dead, get parked, or start
  answering behind an administrative proxy. If the response is not JSON - e.g. it
  begins with `<` - say so plainly ("answered, but not like an Xtream Codes
  portal") instead of reporting a JSON error.
- **Expect provider padding.** Real portals ship blank placeholder rows: no name,
  no EPG id, added in one batch. Hide them from the list, keep the count, and say
  it in the status line ("179 blank entries hidden"). Do not present them as
  channels, and do not silently drop rows that *do* have data.
- XMLTV time format is `yyyyMMddHHmmss Z`; fall back to UTC if the zone is missing.
  Parse with a streaming XMLParser on a background task and drop programmes that
  ended more than ~3 hours ago to bound memory.
- Match XMLTV programmes to channels by `epg_channel_id`. Fall back to
  `get_short_epg` when a channel has no XMLTV data.
- Live HLS playlists commonly 302 to a per-session token URL on a bare IP, and
  their segment URIs are **relative** (`/hls/<token>`). Resolve them against the
  playlist URL after redirects; do not rewrite them.

## DRM protection - what it is, and the honest position

**This app does not play DRM-protected streams, and this is a platform wall, not a
missing feature.** Write the following into the project so nobody re-litigates it:

- The reference Android app has **no DRM implementation of its own**. Its DRM
  support is stock platform code: `android.media.MediaDrm` (Widevine) driven by
  media3/ExoPlayer's `exoplayer.drm` classes - a handful of framework calls out to
  a CDM that the *device* ships. There is nothing in that codebase to port.
- **macOS ships FairPlay, not Widevine**, and Google licenses no Widevine CDM for
  macOS. PlayReady is likewise unavailable. Therefore a native macOS player cannot
  decrypt Widevine- or PlayReady-protected content at any level of effort.
- Do **not** attempt to implement, source, or bypass a DRM system. No key
  extraction, no CDM shims, no "decryption helper". This is a hard boundary, not a
  tuning parameter.

What the app **does** do - graceful detection and reporting:

1. When a stream URL is resolved, fetch the first bytes of the playlist/manifest.
   If it carries an encrypted-media marker (for HLS, an `#EXT-X-KEY` with
   `METHOD=SAMPLE-AES`, or a `#EXT-X-SESSION-KEY`; for DASH, a `<ContentProtection>`
   element), treat the channel as DRM-protected.
2. Fail fast and visibly. Never leave a spinner. The message is specific:
   "This channel is DRM-protected (Widevine/PlayReady). macOS has no CDM for it, so
   no player on this Mac can decrypt it."
3. Offer the one honest escape hatch: copy the stream URL, or "Open in VLC" - and
   note that VLC on macOS fails on these too, so the user is not sent on a chase.
4. Cap it: one probe per channel per session, cached. Do not re-probe on every
   selection.
5. Surface the aggregate in the account menu: "N of your channels advertise
   encrypted media and will not play." The user should be able to see which
   channels are dead to them *before* they wonder why.

Document the limitation in the README as a platform fact with the reason, not as an
apology. Nothing in this section weakens the clean-room or no-circumvention rules.

## Features

### v1 (must ship)

- **Login screen**: server, username, password. Validates via the auth call, shows
  provider errors verbatim, saves to Keychain, auto-signs-in on next launch.
  Sign Out clears the Keychain item.
- **Credential ownership**: the app creates its own Keychain item (a generic
  password under service `IPTVMac`, account `primary`, value a JSON blob). Note that
  a CLI-created item is not trusted by the bundled app and triggers a system prompt
  asking for the *login keychain* password - so the app must be the writer. Since
  ad-hoc signing gives the app a new code identity on every rebuild, expect one
  "Always Allow" prompt after a rebuild; a Developer ID signature removes that.
  Provide a documented one-shot environment import on first run
  (`IPTV_SERVER` / `IPTV_USER` / `IPTV_PASS`) that saves straight into the Keychain,
  so provisioning never writes a password to disk.
- **Sidebar**: Favourites (with count), All Channels (with count), then provider
  categories, alphabetically.
- **Channel list**: logo (async-loaded, placeholder), name, current programme title,
  thin progress bar, favourite star toggle. Search box filters by name. Click plays.
  Mutate playback state **outside** the list's selection update - deferring one
  main-actor turn - because doing it inline is a reentrant operation in
  `NSTableView`'s delegate and is an assert-in-waiting.
- **Player pane**: `AVPlayerView` in floating-controls mode (native control bar,
  PiP, full screen). Under it, a Now/Next panel with title, time range, description.
- **TV Guide**: horizontal timeline grid, ~6 hours starting 30 minutes ago, rounded
  to the half hour. Sticky channel-name column, sticky time header, red "now" line,
  programme blocks sized by duration (~5 pt per minute), lazy rendering, capped at
  ~300 channels per view. Clicking a programme: future or live plays the live
  channel; past plays catch-up.
- **Catch-up**: only when `tv_archive_duration > 0`; a "Back to Live" button while
  watching archive. Verify the UTC timestamp against `date -u` - getting this wrong
  is the single easiest bug in the whole app.
- **Account menu**: status, expiry date, connections used/max, Reload, Sign Out.
- **Favourites** persisted in UserDefaults (by `stream_id`).
- **"Open in VLC"** button: opens the `.ts` URL in VLC.app via `NSWorkspace`, for
  streams AVPlayer cannot handle.

### v2 (after v1 works against a real provider)

Multiple providers/profiles switchable; custom favourite groups, hidden channels,
channel reordering; keyboard navigation (arrows for channels, number-key channel
entry, space to pause, F full screen) and menu-bar commands; last-channel recall and
auto-resume on launch; recording to a chosen folder with scheduling from the guide;
guide reminders via local notifications; multiview 2x2 respecting `max_connections`;
VOD and Series via `get_vod_categories`, `get_vod_streams`, `get_series`,
`get_series_info`, `get_vod_info` with continue-watching; M3U/XMLTV URL playlists as
an additional source type; audio-track and subtitle selection, aspect-ratio and
deinterlace options, buffering settings; guide search and genre colouring.

## Playback notes

- AVPlayer plays HLS (`.m3u8`) well but **cannot play raw MPEG-TS over HTTP**. Many
  portals advertise `allowed_output_formats` of `m3u8, ts, rtmp` - default to HLS.
  If a provider only serves TS, v2 embeds libVLC (or MPVKit) as an alternate engine
  behind a `PlayerEngine` protocol, selectable per provider.
- Handle stream failures: inline error, Retry, and "Open in VLC".
- Respect the provider's connection limit: stop the old stream before starting a new
  one, and never open more simultaneous streams than `max_connections`.

## Suggested architecture

```
Sources/IPTVMacCore/     Flex.swift, Models.swift, XtreamClient.swift, Keychain.swift
Sources/IPTVMac/         App.swift, AppModel.swift, Views.swift
Sources/iptvprobe/       main.swift  (verification harness, see below)
build_app.sh
```

Deliberately avoid the type name `Category` - it collides with the ObjC runtime's
`Category` struct the moment AppKit or AVKit is imported. Use `ChannelCategory`.

## Verification harness (`iptvprobe`)

A CLI that takes the same credentials, either from the environment or from the
Keychain, and proves end-to-end:

1. Base-URL normalisation cases (`host:port`, trailing slash, `/player_api.php`,
   `/get.php`, `/c`, missing scheme).
2. Login: print `auth`, `status`, expiry, `max_connections`, allowed formats - never
   the password. Print the portal URL with the password replaced.
3. Catalogue: category count, channel count, and **decode fidelity** - every row the
   JSON contained must come back with a usable stream id. Report blank placeholder
   rows as information, not as a failure.
4. Short EPG decodes, base64 titles included.
5. Playback: `AVURLAsset.load(.isPlayable)`, then wait for `AVPlayerItem.status ==
   .readyToPlay`, then the only honest proof - **the media clock advances**. Sample
   `player.currentTime()` and require the position to move forward. A playlist that
   fetches is not playback.
6. Catch-up URL formatting, checked against a value verified with `date -u`.

Exit non-zero on any failure. This harness is the acceptance test; a green run of
the app is not.

## Quality bar

- Builds cleanly with `swift build -c release` and `./build_app.sh`, with **zero
  warnings**.
- UI never blocks on network: loading overlays, background XMLTV parsing, lazy lists.
- **Verify the artifact, not the build's exit code.** A build system can report
  success while shipping a stale binary - especially after a corrupted build
  database (`disk I/O error` on `.build/.../build.db`, which happens for real, e.g.
  behind a flaky external disk). After every build, confirm the deployed binary
  actually contains the change, e.g. `strings <binary> | grep <new literal>`. When
  the build database is suspect, `rm -rf .build/out` and rebuild clean.
- Unit tests for: base-URL normalisation, lenient JSON decoding, XMLTV parsing
  (including timezone variants), catch-up URL formatting (UTC, minutes), now/next
  selection, DRM marker detection.
- Test against a local mock Xtream server (a small script serving fixture
  JSON/XMLTV) so no real credentials are needed in tests.
- Verify by running the app and confirming: login error path, channel list renders,
  guide renders, favourites persist across relaunch, sign-out clears the Keychain,
  and a channel decodes to moving video.

## Deliverables

- Source tree plus `build_app.sh` producing `OS TV.app`.
- A short README: how to build, how to sign in, and known limitations (TS-only
  providers, DRM-protected streams, and the platform reason for each).
- A summary of what was verified, and what could not be verified without a real
  provider.
- **Never committed**: credentials, a portal URL in source, or anything lifted from
  a third-party app.
