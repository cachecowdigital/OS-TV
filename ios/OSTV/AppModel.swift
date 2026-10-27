import Foundation
import SwiftUI
import IPTVMacCore

/// Everything the iOS app knows, in one observable object.
///
/// Deliberately smaller than the Mac `AppModel`: no multi-playlist library, no parental
/// locks, no EPG grid yet. It does the things a phone needs — sign in once, browse the
/// provider's live channels and movies, and play them — using the same `IPTVMacCore`
/// client, parsers and URL builders the Mac app ships, so the two cannot drift apart in
/// how they talk to a portal.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case connecting(String)
        case ready
        case failed(String)
    }

    struct NowPlaying: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let url: URL
        var isLive: Bool
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var account: Account?
    @Published private(set) var categories: [ChannelCategory] = []
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var movies: [VODStream] = []
    @Published private(set) var favourites: Set<Int> = []
    @Published var searchText: String = ""
    @Published var categoryFilter: String? = nil
    @Published var nowPlaying: NowPlaying?
    @Published private(set) var signedInAs: String = ""

    private var client: XtreamClient?
    private let favouritesKey = "favourites.streamIDs"

    var isBusy: Bool {
        if case .connecting = phase { return true }
        return false
    }

    var isSignedIn: Bool {
        if case .ready = phase { return true }
        return false
    }

    // MARK: - Lifetime

    /// Called once when the root view appears: restore a saved subscription, or, in a debug
    /// build only, accept credentials handed in through the environment so an automated
    /// launch can sign in without anyone typing a password on the device.
    func bootstrap() {
        favourites = Set(UserDefaults.standard.array(forKey: favouritesKey) as? [Int] ?? [])
        if let saved = CredentialStore.load() {
            Log.write("bootstrap: restored saved subscription for \(saved.redacted)")
            signedInAs = saved.redacted
            Task { await connect(saved, remember: false) }
            return
        }
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let server = env["OS_TV_SERVER"], let user = env["OS_TV_USER"], let pass = env["OS_TV_PASS"],
           !server.isEmpty, !user.isEmpty, !pass.isEmpty {
            Log.write("bootstrap: using debug credentials from environment")
            let credentials = Credentials(server: server, username: user, password: pass)
            signedInAs = credentials.redacted
            Task { await connect(credentials, remember: true) }
            return
        }
        #endif
        Log.write("bootstrap: no saved subscription")
    }

    func connect(server: String, username: String, password: String) async {
        let credentials = Credentials(server: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                      username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                      password: password)
        signedInAs = credentials.redacted
        await connect(credentials, remember: true)
    }

    private func connect(_ credentials: Credentials, remember: Bool) async {
        phase = .connecting("Signing in…")
        Log.write("connect: \(credentials.redacted)")
        let client = XtreamClient(credentials: credentials)
        self.client = client
        do {
            let account = try await client.login()
            client.panelTimeZone = TimeZone(identifier: account.serverInfo.timezone)
            self.account = account
            Log.write("connect: auth=1 status=\(account.userInfo.status) " +
                      "expires=\(account.userInfo.expiryText) connections=\(account.userInfo.activeConnections)/\(account.userInfo.maxConnections)")

            phase = .connecting("Loading channels…")
            async let categoriesTask = client.liveCategories()
            async let streamsTask = client.liveStreams()
            let (cats, streams) = try await (categoriesTask, streamsTask)
            categories = cats
            channels = streams.sorted { $0.number < $1.number }
            Log.write("catalogue: \(channels.count) live channels in \(categories.count) categories")
            if let first = channels.first {
                Log.write("catalogue: first channel id=\(first.streamID) name=\"\(first.name)\" " +
                          "cat=\(first.categoryID ?? "nil") archive=\(first.hasArchive)")
            }

            phase = .connecting("Loading movies…")
            if let vodCats = try? await client.vodCategories(),
               let vod = try? await client.vodStreams() {
                movies = vod
                Log.write("catalogue: \(movies.count) movies in \(vodCats.count) categories")
            } else {
                Log.write("catalogue: no movies on this account (or the call failed)")
            }

            if remember { try? CredentialStore.save(credentials) }
            phase = .ready
            Log.write("connect: ready")
        } catch {
            Log.write("connect FAILED: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        CredentialStore.delete()
        client = nil
        account = nil
        categories = []
        channels = []
        movies = []
        categoryFilter = nil
        nowPlaying = nil
        phase = .signedOut
        signedInAs = ""
        Log.write("signOut: cleared saved subscription")
    }

    /// Retry after a failed sign-in without re-typing anything.
    func retry() {
        guard let saved = CredentialStore.load() else { phase = .signedOut; return }
        Task { await connect(saved, remember: false) }
    }

    // MARK: - Lists

    /// Channels for the current category filter and search text, computed once per change
    /// rather than inside a `ForEach` — the Mac app learned that lesson on 9,000 rows.
    var visibleChannels: [Channel] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return channels.filter { channel in
            (categoryFilter == nil || channel.categoryID == categoryFilter) &&
            (query.isEmpty || channel.name.lowercased().contains(query))
        }
    }

    var visibleMovies: [VODStream] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return movies }
        return movies.filter { $0.name.lowercased().contains(query) }
    }

    func categoryName(_ id: String?) -> String? {
        categories.first { $0.id == id }?.name
    }

    func isFavourite(_ channel: Channel) -> Bool { favourites.contains(channel.streamID) }

    func toggleFavourite(_ channel: Channel) {
        if favourites.contains(channel.streamID) {
            favourites.remove(channel.streamID)
        } else {
            favourites.insert(channel.streamID)
        }
        UserDefaults.standard.set(Array(favourites), forKey: favouritesKey)
    }

    // MARK: - Playback

    func play(_ channel: Channel) {
        guard let client else { return }
        let formats = account?.userInfo.allowedOutputFormats ?? []
        let preferred = formats.contains("m3u8") || formats.isEmpty ? "m3u8" : formats[0]
        guard let url = client.liveURL(streamID: channel.streamID, format: preferred) else {
            Log.write("play: could not build a URL for channel \(channel.streamID)")
            return
        }
        Log.write("play: \"\(channel.name)\" (\(channel.streamID)) as \(preferred) -> \(url.host ?? "?")\(url.path)")
        nowPlaying = NowPlaying(id: "live-\(channel.streamID)", title: channel.name,
                                subtitle: categoryName(channel.categoryID) ?? "Live TV",
                                url: url, isLive: true)
    }

    func play(_ movie: VODStream) {
        guard let client else { return }
        guard let url = client.vodURL(streamID: movie.streamID, ext: movie.containerExtension) else {
            Log.write("play: could not build a VOD URL for \(movie.streamID)")
            return
        }
        Log.write("play: movie \"\(movie.name)\" (\(movie.streamID)) .\(movie.containerExtension) -> \(url.host ?? "?")\(url.path)")
        nowPlaying = NowPlaying(id: "vod-\(movie.streamID)", title: movie.name,
                                subtitle: movie.rating.map { "★ \($0)" } ?? "Movie",
                                url: url, isLive: false)
    }

    func stopPlayback() {
        nowPlaying = nil
    }

    // MARK: - Diagnostics

    var diagnosticsSummary: String {
        """
        server: \(account?.serverInfo.host ?? "—"):\(account?.serverInfo.port ?? "—")
        panel: Xtream \(account?.serverInfo.version ?? "?") ui=\(account?.serverInfo.isXtreamUI == true)
        status: \(account?.userInfo.status ?? "—") expiry: \(account?.userInfo.expiryText ?? "—")
        connections: \(account?.userInfo.activeConnections ?? 0)/\(account?.userInfo.maxConnections ?? 0)
        channels: \(channels.count)  categories: \(categories.count)  movies: \(movies.count)
        """
    }
}
