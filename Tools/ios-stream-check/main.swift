// Checks the exact request path the iOS app uses, against the subscription already saved
// in the login keychain by the Mac app. Prints no host, username or password — only counts,
// status codes and content types, so its output is safe to paste in a message.
//
//   swiftc -O Tools/ios-stream-check/main.swift Sources/IPTVMacCore/*.swift -o /tmp/ios-stream-check && /tmp/ios-stream-check

import Foundation
import AVFoundation

func say(_ s: String) { print(s) }

guard let credentials = CredentialStore.load() else {
    say("NO CREDENTIALS: nothing saved in the keychain under service IPTVMac / account primary")
    exit(2)
}
say("subscription: \(credentials.redacted.components(separatedBy: "@").first ?? "saved") saved in keychain")

let client = XtreamClient(credentials: credentials)
let sem = DispatchSemaphore(value: 0)
var failures = 0

func step(_ name: String, _ body: @escaping () async throws -> String) async {
    do {
        let detail = try await body()
        say("PASS \(name): \(detail)")
    } catch {
        failures += 1
        say("FAIL \(name): \(error.localizedDescription)")
    }
}

Task {
    var account: Account?
    await step("login") {
        let a = try await client.login()
        account = a
        client.panelTimeZone = TimeZone(identifier: a.serverInfo.timezone)
        return "auth=\(a.userInfo.auth) status=\(a.userInfo.status) expiry=\(a.userInfo.expiryText) " +
               "connections=\(a.userInfo.activeConnections)/\(a.userInfo.maxConnections) " +
               "formats=\(a.userInfo.allowedOutputFormats.joined(separator: ","))"
    }

    var channels: [Channel] = []
    await step("live categories") {
        let cats = try await client.liveCategories()
        return "\(cats.count) categories"
    }
    await step("live streams") {
        channels = try await client.liveStreams()
        let withIcons = channels.filter { ($0.iconURL ?? "").isEmpty == false }.count
        return "\(channels.count) channels, \(withIcons) with logos, " +
               "\(Set(channels.compactMap(\.categoryID)).count) distinct categories"
    }

    // Exactly what AppModel.play() builds: the first of the account's allowed formats.
    let formats = account?.userInfo.allowedOutputFormats ?? []
    let preferred = formats.contains("m3u8") || formats.isEmpty ? "m3u8" : formats[0]
    say("selected format: \(preferred)")

    for channel in channels.prefix(3) {
        guard let url = client.liveURL(streamID: channel.streamID, format: preferred) else {
            say("FAIL live URL for stream \(channel.streamID)"); failures += 1; continue
        }
        var request = URLRequest(url: url)
        request.setValue(XtreamClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"
            let ok = (http?.statusCode ?? 0) < 400 && !data.isEmpty
            say("\(ok ? "PASS" : "FAIL") live stream \(channel.streamID) (\"\(channel.name)\"): " +
                "HTTP \(http?.statusCode ?? 0), \(data.count) bytes, \(type)")
            if !ok { failures += 1 }
        } catch {
            say("FAIL live stream \(channel.streamID): \(error.localizedDescription)"); failures += 1
        }
    }

    // Playback: the same AVPlayer path the iOS PlayerView uses.
    if let first = channels.first, let url = client.liveURL(streamID: first.streamID, format: preferred) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.play()
        var waited = 0.0
        while item.status == .unknown, waited < 30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 0.5
        }
        switch item.status {
        case .readyToPlay:
            let loaded = item.loadedTimeRanges.count
            say("PASS avplayer ready in \(String(format: "%.1f", waited))s, " +
                "duration=\(item.duration.seconds), loaded ranges=\(loaded)")
        case .failed:
            failures += 1
            say("FAIL avplayer: \(item.error?.localizedDescription ?? "unknown")")
        default:
            failures += 1
            say("FAIL avplayer: still unknown after \(Int(waited))s")
        }
        player.pause()
    }

    await step("vod categories") {
        let cats = try await client.vodCategories()
        return "\(cats.count) categories"
    }
    await step("vod streams") {
        let movies = try await client.vodStreams()
        return "\(movies.count) movies"
    }

    say(failures == 0 ? "RESULT: all checks passed" : "RESULT: \(failures) failure(s)")
    sem.signal()
}

sem.wait()
exit(failures == 0 ? 0 : 1)
