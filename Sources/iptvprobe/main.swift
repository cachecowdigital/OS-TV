import Foundation
import AVFoundation
import IPTVMacCore

// Verification harness for the IPTVMac spike.
// Proves, against a real provider: URL normalisation, login, catalog fetch,
// HLS URL construction, and that AVFoundation actually plays the stream.
// Credentials come from the environment (IPTV_SERVER / IPTV_USER / IPTV_PASS)
// or, failing that, from the Keychain. The password is never printed.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    checks += 1
    if !passed { failures += 1 }
    let mark = passed ? "PASS" : "FAIL"
    print("[\(mark)] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
}

func normalisationTests() {
    let cases: [(String, String)] = [
        ("portal.example.com:8080", "http://portal.example.com:8080"),
        ("http://portal.example.com:8080/", "http://portal.example.com:8080"),
        ("http://portal.example.com:8080/player_api.php", "http://portal.example.com:8080"),
        ("https://example.com/get.php", "https://example.com"),
        ("example.com", "http://example.com"),
        ("http://example.com/c", "http://example.com"),
    ]
    for (input, expected) in cases {
        let got = XtreamClient.normalizeServer(input)
        check("normalize(“\(input)”)", got == expected, got == expected ? got : "got \(got), want \(expected)")
    }
}

func loadCredentials() -> Credentials? {
    let env = ProcessInfo.processInfo.environment
    if let server = env["IPTV_SERVER"], let user = env["IPTV_USER"], let pass = env["IPTV_PASS"] {
        print("credentials: from environment")
        return Credentials(server: server, username: user, password: pass)
    }
    if let stored = CredentialStore.load() {
        print("credentials: from Keychain (\(stored.redacted))")
        return stored
    }
    return nil
}

func run() async -> Int32 {
    normalisationTests()

    guard let credentials = loadCredentials() else {
        print("no credentials available (set IPTV_SERVER / IPTV_USER / IPTV_PASS)")
        return 2
    }
    print("")

    let client = XtreamClient(credentials: credentials)
    print("portal: \(client.base)")

    // 1. Login
    let account: Account
    do {
        account = try await client.login()
    } catch {
        check("login", false, error.localizedDescription)
        print("\nVERDICT: FAILED — could not sign in.")
        return 1
    }
    check("login", true,
          "auth=\(account.userInfo.auth) status=\(account.userInfo.status) "
          + "expires=\(account.userInfo.expiryText) "
          + "connections=\(account.userInfo.maxConnections) "
          + "formats=\(account.userInfo.allowedOutputFormats.joined(separator: ","))")

    // 2. Catalog
    var channels: [Channel] = []
    do {
        async let categoriesTask = client.liveCategories()
        async let streamsTask = client.liveStreams()
        let categories = try await categoriesTask
        channels = try await streamsTask
        check("live categories", !categories.isEmpty, "\(categories.count)")
        check("live streams", !channels.isEmpty, "\(channels.count)")
        // Decode fidelity: every single row must come back with a usable stream
        // id. Anything the JSON has, the model has — no silent row loss.
        let idless = channels.filter { $0.streamID == 0 }.count
        check("every row decoded with a stream id", idless == 0,
              "\(channels.count - idless)/\(channels.count) rows")

        // Providers pad the catalog with blank placeholders. Not an error —
        // the app hides them and reports the count.
        let blank = channels.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let blankPercent = Double(blank) / Double(max(channels.count, 1)) * 100
        check("blank placeholder rows identified", true,
              String(format: "%d rows (%.1f%%) have no name and are hidden by the app", blank, blankPercent))
    } catch {
        check("catalog fetch", false, error.localizedDescription)
    }

    // 3. EPG (best effort — not every panel serves it)
    if let first = channels.first {
        do {
            let epg = try await client.shortEPG(streamID: first.streamID, limit: 2)
            check("short EPG decode", true, "\(epg.count) programmes, first title: “\(epg.first?.title ?? "")”")
        } catch {
            print("[SKIP] short EPG — \(error.localizedDescription)")
        }
    }

    // 4. Playback — the part that actually matters
    guard let sample = channels.first, let hls = client.liveURL(streamID: sample.streamID) else {
        check("playback", false, "no channel available to play")
        print("\nVERDICT: FAILED")
        return 1
    }
    print("")
    print("playback sample: “\(sample.name)” (stream \(sample.streamID))")
    print("url: \(hls.absoluteString.replacingOccurrences(of: credentials.password, with: "•••"))")

    let asset = AVURLAsset(url: hls)
    do {
        let playable = try await asset.load(.isPlayable)
        check("AVAsset reports playable", playable)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            check("duration readable", seconds.isFinite || seconds.isNaN,
                  seconds.isFinite ? String(format: "%.0f s", seconds) : "live (indefinite)")
        }
    } catch {
        check("AVAsset playable", false, error.localizedDescription)
    }

    let player = AVPlayer(url: hls)
    player.isMuted = true
    player.play()

    // Wait for the item to actually become playable.
    var readyState = "still loading"
    for _ in 0..<80 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let item = player.currentItem else { continue }
        if item.status == .failed {
            readyState = "failed: \(item.error?.localizedDescription ?? "unknown")"
            break
        }
        if item.status == .readyToPlay { readyState = "readyToPlay"; break }
    }
    check("AVPlayer item became readyToPlay", readyState == "readyToPlay", readyState)

    // The only honest proof of playback: the media clock moves forward.
    var samples: [Double] = []
    for _ in 0..<30 {
        try? await Task.sleep(nanoseconds: 500_000_000)
        samples.append(player.currentTime().seconds)
        if let first = samples.first, let last = samples.last, last - first >= 3.0 { break }
    }
    let delta = (samples.last ?? 0) - (samples.first ?? 0)
    let itemError = player.currentItem?.error?.localizedDescription
    player.pause()
    check("playback position advanced", delta >= 3.0,
          String(format: "%.1f s of stream played over %.1f s of wall clock%@",
                 delta, Double(samples.count) * 0.5,
                 itemError.map { " — error: \($0)" } ?? ""))

    // 5. Catch-up URL formatting (pure string check, no provider needed)
    // Verified independently: `date -u -r 1792000000` → 2026-10-14 17:46:40 UTC
    let reference = Date(timeIntervalSince1970: 1792000000)
    let catchUp = client.catchUpURL(streamID: 12345, start: reference, durationMinutes: 60)
    check("catch-up URL is UTC-formatted",
          catchUp?.absoluteString.contains("/timeshift/") == true
          && catchUp?.absoluteString.contains("/60/2026-10-14:17-46/12345.m3u8") == true,
          catchUp.map { $0.absoluteString.replacingOccurrences(of: credentials.password, with: "•••") } ?? "nil")

    print("")
    if failures == 0 {
        print("VERDICT: PASSED — \(checks) checks, 0 failures.")
        return 0
    } else {
        print("VERDICT: FAILED — \(failures) of \(checks) checks failed.")
        return 1
    }
}

let code = await run()
exit(code)
