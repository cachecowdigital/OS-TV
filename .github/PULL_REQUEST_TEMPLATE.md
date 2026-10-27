## What was broken

<!-- The symptom, and where you saw it (Live TV / Guide / Movies & Series / Settings). -->

## What changed

<!-- One or two sentences. Call out anything a reviewer should look at closely. -->

## How I verified it

<!-- Required. A screenshot, a log line, or the test you added. "Looks fixed" doesn't count. -->

- [ ] `swift build && swift test` green locally (58 tests, 0 failures)
- [ ] No credentials, provider hosts, or usernames anywhere in this diff
- [ ] Bundle id `ca.benyik.jabcorptv` untouched, no build artifacts committed
- [ ] Clean-room: nothing copied or decompiled from another IPTV app
- [ ] Model/parser change includes a test in `IPTVMacCoreTests`

## Screenshots

<!-- For UI changes: before / after. Blur any provider name or credential. -->
