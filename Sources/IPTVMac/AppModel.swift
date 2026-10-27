import Foundation
import AVFoundation
import AppKit
import Combine
import IPTVMacCore

/// Sentinel selection meaning "every channel from every category".
/// Lives outside the @MainActor model so nonisolated filters can read it.
public enum CatalogSelection {
    public static let allChannelsID = "ALL"
    public static let favouritesID = "FAVOURITES"
    public static let recentsID = "RECENTS"
    /// Movies and series are selected by a prefixed id ("VOD:912", "SERIES:ALL") rather than a
    /// bare category id: a provider numbers live, VOD and series categories independently from
    /// 1, so an unprefixed id would risk a VOD category silently matching a live one.
    public static let vodPrefix = "VOD:"
    public static let seriesPrefix = "SERIES:"
    public static let allSuffix = "ALL"
    public static let vodAllID = vodPrefix + allSuffix
    public static let seriesAllID = seriesPrefix + allSuffix
}

/// The icon rail's three tabs — TiviMate's two-level sidebar (a narrow icon rail plus a
/// per-section category panel) rather than one flat list mixing live, movies and series
/// together. Search and Settings live outside this enum: search is each content view's own
/// native `.searchable` field, and Settings is the app's standard scene, not a sidebar tab.
public enum SidebarSection: Equatable {
    case live, movies, series
}

/// `addSubscription`'s result. Not `Result<PlaylistID, String>` — plain `String` doesn't conform
/// to `Error`, and wrapping it in one just to satisfy that would be more ceremony than this needs.
public enum AddSubscriptionOutcome {
    case success(PlaylistID)
    case failure(String)
}

public struct GuideRowData: Identifiable, Sendable {
    public let channel: Channel
    public let programmes: [XMLTVProgramme]
    public var id: Int { channel.streamID }
}

@MainActor
public final class AppModel: ObservableObject {

    public static let allCategoryID = CatalogSelection.allChannelsID

    public enum Phase: Equatable {
        case signedOut
        case connecting
        case ready
        case failed(String)
    }

    @Published public var phase: Phase = .signedOut
    @Published public var account: Account?
    @Published public var categories: [ChannelCategory] = []
    @Published public var channels: [Channel] = []
    @Published public var statusLine: String = "Not signed in"
    @Published public var banner: String?

    // VOD (movies) and series (TV shows). Loaded best-effort alongside the live catalog: a
    // provider that doesn't carry VOD/series must not block or slow down live channels, so
    // failures here are swallowed and simply leave these lists empty.
    @Published public var vodCategories: [ChannelCategory] = []
    @Published public var vodStreams: [VODStream] = []
    @Published public var seriesCategories: [ChannelCategory] = []
    @Published public var seriesList: [SeriesSummary] = []
    @Published public private(set) var filteredVOD: [VODStream] = []
    @Published public private(set) var filteredSeries: [SeriesSummary] = []

    public let settings = AppSettings()
    public let favourites = FavouritesStore()

    // Selection. `filteredChannels` is CACHED rather than computed: a computed
    // property re-filtered all 9,130 channels on every render pass, which showed
    // up as a reentrant NSTableView delegate warning on first population.
    @Published public var selectedCategoryID: String = AppModel.allCategoryID {
        didSet { recomputeFilter() }
    }
    /// Which icon-rail tab is active. Kept separate from `selectedCategoryID` (which still
    /// carries the actual filter) because switching tabs needs to pick a sensible landing
    /// category for the NEW section — it must never just leave the old section's category id
    /// selected while showing a different section's list.
    @Published public var sidebarSection: SidebarSection = .live
    @Published public var searchText: String = "" {
        didSet { recomputeFilter() }
    }
    @Published public private(set) var filteredChannels: [Channel] = []
    private var lastLoggedFilterCategory = ""
    private var lastLoggedFilterCount = -1
    @Published public var selectedChannel: Channel?

    // Guide
    @Published public private(set) var guideProgrammes: [Int: [XMLTVProgramme]] = [:]
    @Published public private(set) var guideChannels: [Channel] = []
    @Published public private(set) var epgProgrammeCount = 0
    @Published public var isLoadingGuide = false
    @Published public var guideStatus = "No guide loaded yet."

    // Playback
    @Published public var nowPlayingTitle: String = ""
    @Published public var nowPlayingDetail: String = ""
    @Published public var isCatchUp = false
    @Published public var catchUpRange: String = ""
    @Published public var lastError: String?
    /// True while a movie or episode is on screen, as opposed to a live channel. The two paths
    /// never overlap: starting one clears the other's selection, so the player pane can tell
    /// which set of controls (and which retry/VLC/stop plumbing) applies from this flag alone.
    @Published public var nowPlayingIsMedia = false

    /// True while the window is in macOS full screen. Driven by the system's own
    /// notifications, so the green button, ⌃⌘F and our buttons all agree.
    @Published public var isFullScreenPlayer = false

    // Parental
    @Published public var parentalUnlocked = false
    @Published public private(set) var lockedCategoryIDs: Set<String> = []
    @Published public private(set) var lockedChannelCount = 0

    @Published public var diagnosticsResult = "Run diagnostics to test the provider from this Mac."

    public let player = AVPlayer()

    /// Set when the provider refused the stream outright. The player then offers Retry and
    /// the VLC fallback instead of a spinner that never resolves.
    @Published public var playbackFailed = false
    private var statusTask: Task<Void, Never>?
    private var lastPlaybackRequest: (url: URL, channel: Channel, catchUp: (Date, Date)?)?
    /// Movies and episodes have a single, already-known URL — no container ladder to climb the
    /// way live/catch-up have one — so they get their own small status task and retry state
    /// rather than being threaded through the live-channel machinery above, which rebuilds its
    /// retry URL from a channel's `streamID` in ways that would be meaningless for a VOD id.
    private var mediaStatusTask: Task<Void, Never>?
    private var lastMediaRequest: (url: URL, title: String)?
    /// The container formats this zap has already tried. A channel one container refuses often
    /// serves in the other, so a refusal advances here instead of giving up on the channel.
    private var triedFormats: Set<String> = []
    /// Why each format refused, kept so the final message says what actually happened.
    private var formatRefusals: [String: String] = [:]
    /// How many times each container has refused during this zap.
    private var formatAttempts: [String: Int] = [:]
    /// When the next reachability probe may run. Probes are spaced out because a refusal has to
    /// repeat before it means anything.
    private var nextProbeAt = Date.distantPast
    /// A refusal is evidence, not a verdict. This provider's portal redirects every stream to an
    /// edge node, and that edge serves HTTP 200 one moment and a 404 or an empty HTML page the
    /// next for the same healthy channel — so one refusal, however definite it looks, cannot be
    /// trusted. Every container gets this many tries before it counts as refused.
    static let attemptsPerFormat = 3

    private var client: XtreamClient?
    private var nowPlayingTask: Task<Void, Never>?
    private var catalogStats = ""

    // Saved subscriptions. The app still connects to exactly ONE provider at a time — this is
    // switching, not the simultaneous-multi-provider-merge design `Playlist`'s other fields
    // (epg, epgShiftMinutes, ...) were built for and that this doesn't touch. Each playlist's
    // login lives in its own Keychain item (`playlist.id.keychainAccount`), never in this
    // UserDefaults-backed index — the index only ever holds the non-secret name and host, same
    // rule the single-subscription path already followed.
    public let library = LibraryStore()
    @Published public private(set) var subscriptions: [Playlist] = []
    @Published public private(set) var activeSubscriptionID: PlaylistID?

    public init() {
        player.actionAtItemEnd = .none
        // macOS 13 migration: `settings` and `favourites` are separate ObservableObjects held
        // as `let`, so their changes must be re-published up through the model.
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        favourites.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Session

    public var isSignedIn: Bool {
        // The phase is what records that a session is open. `account` is only the
        // portal's description of that account, and a session can be live without one —
        // the on-disk guide fixture has no portal at all.
        if case .ready = phase { return true }
        return account != nil
    }

    public var visibleChannels: [Channel] { filteredChannels }

    /// The guide's channel column, which now honours the sidebar selection.
    ///
    /// It did not, and that was a real fault: picking a category changed the channel *list*, a pane
    /// that is not on screen while the guide is open, so with the guide showing, a category pick
    /// looked like it did nothing at all. Channels in the selection that carry no guide still
    /// appear, with empty programme cells — "this group" is what was asked for, and silently
    /// showing nothing would be the same complaint again.
    public var guideVisibleChannels: [Channel] {
        // Matched against `guideProgrammes` directly — keyed by streamID, rebuilt from ALL
        // channels every time the guide loads, so it's always fresh — rather than against
        // `guideChannels`, which is a SNAPSHOT scoped to whatever category happened to be
        // selected the last time `rebuildGuideProgrammes()` ran (guide reload, a settings
        // change, an EPG-shift nudge — anything but a plain sidebar click, which only calls
        // `recomputeFilter()`). That staleness used to self-correct via the empty-check below
        // falling back to the unfiltered category — except for a category over 300 channels
        // (GuideView's own display cap), where the real matches could land outside the first
        // 300 in catalog order and the grid reported "no guide data" for a category the plain
        // channel list — which reads `guideProgrammes` the same direct way — showed correctly.
        guard selectedCategoryID != AppModel.allCategoryID else {
            let matched = channels.filter { guideProgrammes[$0.streamID] != nil }
            return matched.isEmpty ? channels : matched
        }
        let matched = filteredChannels.filter { guideProgrammes[$0.streamID] != nil }
        return matched.isEmpty ? filteredChannels : matched
    }

    public var connectionText: String {
        guard let info = account?.userInfo else { return "—" }
        return "\(info.activeConnections)/\(info.maxConnections) connections"
    }

    /// Host shown in the UI. The full URL is never printed anywhere.
    public var portalHost: String {
        // Read from the live client rather than the Keychain: this is evaluated while
        // rendering, and a Keychain read per render pass is both wasteful and — on a
        // build the item does not yet trust — a prompt per render pass.
        guard let raw = client?.base else { return "—" }
        return URL(string: raw)?.host ?? raw
    }

    public func bootstrap() async {
        if let fixture = ProcessInfo.processInfo.environment["IPTV_GUIDE_FILE"] {
            await loadGuideFixture(from: fixture)
            return
        }

        var index = library.load()
        migrateLegacyPrimaryIntoLibrary(&index)
        subscriptions = index.orderedPlaylists
        activeSubscriptionID = index.activePlaylistID

        if let activeID = index.activePlaylistID,
           let playlist = index.playlists.first(where: { $0.id == activeID }),
           let saved = CredentialStore.load(account: playlist.id.keychainAccount) {
            await connect(with: saved, remember: false, playlistID: playlist.id)
            return
        }

        if let saved = CredentialStore.load() {
            // One-time migration: re-save so the item no longer requires
            // per-application authorisation after every rebuild. See the note on
            // CredentialStore.save for why, and for what it costs.
            let migrated = "jabcorptv.keychain.openAccess"
            if !UserDefaults.standard.bool(forKey: migrated) {
                do {
                    try CredentialStore.save(saved)
                    UserDefaults.standard.set(true, forKey: migrated)
                    writeGuideDiagnostics("keychain item re-saved with open access")
                } catch {
                    writeGuideDiagnostics("keychain migration failed: \(error.localizedDescription)")
                }
            }
            await connect(with: saved, remember: false)
            return
        }
        // First run, nothing stored yet. Allow a one-shot import from the
        // environment (provisioning, scripts, CI) and put it straight into the
        // Keychain — from then on the app owns the item and reads it silently.
        let env = ProcessInfo.processInfo.environment
        if let server = env["IPTV_SERVER"],
           let username = env["IPTV_USER"],
           let password = env["IPTV_PASS"] {
            statusLine = "Importing credentials from environment…"
            await connect(with: Credentials(server: server, username: username, password: password),
                          remember: true)
            return
        }
        phase = .signedOut
    }

    /// A sign-in the user wants kept creates a tracked subscription immediately — not just a
    /// "primary" Keychain save the way this worked before multiple subscriptions existed. That
    /// used to leave a real gap: sign in once here, then use "Add Subscription" for a second
    /// one before ever relaunching, and the FIRST login's "primary" item would never become a
    /// playlist (migration only ever runs once, when the library is still completely empty) —
    /// permanently invisible in Manage Subscriptions from then on, even though it was still the
    /// active session. Every remembered sign-in is now a playlist from the moment it succeeds.
    public func signIn(server: String, username: String, password: String, remember: Bool) async {
        guard remember else {
            await connect(with: Credentials(server: server, username: username, password: password),
                         remember: false)
            return
        }
        let credentials = Credentials(server: server, username: username, password: password)
        let host = XtreamClient.normalizeServer(server)
        let playlist = Playlist(id: PlaylistID(), name: displayName(forHost: host), kind: .xtream(host: host))
        do {
            try CredentialStore.save(credentials, account: playlist.id.keychainAccount)
        } catch {
            // Keychain write failed — fall back to the single legacy slot rather than failing
            // the sign-in outright over a problem unrelated to the login itself.
            await connect(with: credentials, remember: true)
            return
        }
        var index = library.load()
        index.add(playlist)
        library.save(index)
        subscriptions = index.orderedPlaylists
        await connect(with: credentials, remember: false, playlistID: playlist.id)
    }

    private func displayName(forHost host: String) -> String { URL(string: host)?.host ?? host }

    /// `playlistID` is the only part that is new: when set, a successful login also records
    /// this as the library's active subscription, so the next launch resumes the same one
    /// instead of falling back to the legacy single-subscription slot. Every existing call site
    /// omits it and behaves exactly as before.
    private func connect(with credentials: Credentials, remember: Bool,
                         playlistID: PlaylistID? = nil) async {
        phase = .connecting
        banner = nil
        let candidate = XtreamClient(credentials: credentials)
        do {
            let account = try await candidate.login()
            if remember { try? CredentialStore.save(credentials) }
            await activate(candidate, account: account, playlistID: playlistID)
        } catch {
            phase = .failed(error.localizedDescription)
            banner = error.localizedDescription
        }
    }

    /// The part of connecting that happens once a login has already succeeded — shared by
    /// `connect()` (which does its own login first) and `switchSubscription` (which validates
    /// the new provider itself, before touching anything, and hands the already-logged-in
    /// client straight in here rather than logging in a second time for the same credentials).
    private func activate(_ candidate: XtreamClient, account: Account, playlistID: PlaylistID?) async {
        candidate.panelTimeZone = TimeZone(identifier: account.serverInfo.timezone)
        self.client = candidate
        self.account = account
        if let playlistID {
            activeSubscriptionID = playlistID
            var index = library.load()
            index.activePlaylistID = playlistID
            library.save(index)
        }
        phase = .ready
        statusLine = "Signed in as \(account.userInfo.username) — \(account.userInfo.status)"
        await loadCatalog()
        // Fire-and-forget: a 36,000-movie catalog is slow to fetch and parse, and must never
        // hold up the guide download behind it, or a provider with no VOD/series at all from
        // delaying sign-in on calls this app doesn't actually need. `candidate` (not
        // `self.client`) is what this fetch is FOR — see loadVODCatalog's own comment on why
        // that distinction is the whole fix for a switch-mid-fetch race.
        Task { [weak self] in await self?.loadVODCatalog(for: candidate) }
        await loadGuide(force: false)
    }

    public func loadCatalog() async {
        guard let client else { return }
        banner = nil
        statusLine = "Loading channels…"
        do {
            async let categoriesTask = client.liveCategories()
            async let streamsTask = client.liveStreams()
            let categories = try await categoriesTask
            let channels = try await streamsTask
            // Providers pad their catalog with blank placeholder rows that can
            // never be played. Keep them out of the list but report the count.
            let usable = channels.filter {
                $0.streamID != 0 && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
            }
            let hidden = channels.count - usable.count
            self.categories = categories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.channels = usable.sorted { ($0.number, $0.name) < ($1.number, $1.name) }
            catalogStats = "\(usable.count) channels • \(self.categories.count) categories"
                + (hidden > 0 ? " • \(hidden) blank entries hidden" : "")
            statusLine = catalogStats
            rebuildLockedCategories()

            // Automation seam, same shape as IPTV_RESUME_STREAM: select a sidebar group by id or
            // by name at launch, so the guide's response to a category pick can be verified
            // without clicking anything.
            if let wanted = ProcessInfo.processInfo.environment["IPTV_CATEGORY"], !wanted.isEmpty {
                if let match = categories.first(where: {
                    $0.id == wanted
                        || $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
                }) {
                    selectedCategoryID = match.id
                    writeGuideDiagnostics("category: selected \(match.name) (\(match.id))")
                } else {
                    writeGuideDiagnostics("category: \(wanted) matched nothing")
                }
            }
            recomputeFilter()

            // Automation / resume seam. `IPTV_RESUME_STREAM=<stream id>` wins;
            // otherwise honour "resume the last channel on launch".
            let env = ProcessInfo.processInfo.environment
            if let raw = env["IPTV_RESUME_STREAM"], let wanted = Int(raw) {
                if let channel = self.channels.first(where: { $0.streamID == wanted }) {
                    writeGuideDiagnostics("resume: stream \(wanted) matched \(channel.name)")
                    Task { @MainActor in play(channel) }
                } else {
                    writeGuideDiagnostics("resume: stream \(wanted) not in the catalogue")
                }
            } else if settings.data.resumeLastChannel,
                      let recent = favourites.data.recentStreamIDs.first,
                      let channel = self.channels.first(where: { $0.streamID == recent }) {
                writeGuideDiagnostics("resume: last watched \(recent) matched \(channel.name)")
                Task { @MainActor in play(channel) }
            } else {
                writeGuideDiagnostics("resume: nothing to resume"
                    + " (recent=\(favourites.data.recentStreamIDs.first.map(String.init) ?? "none")"
                    + " setting=\(settings.data.resumeLastChannel))")
            }

            // Automation seam, same shape as the others: start with the timeline walked back or
        // forward, so the shift can be verified without clicking anything.
        if let raw = ProcessInfo.processInfo.environment["IPTV_GUIDE_JUMP"],
           let minutes = Int(raw) {
            jumpGuide(byMinutes: minutes)
            writeGuideDiagnostics("guide jump: \(minutes) minutes from the environment")
        }

        // Automation seam, same shape as IPTV_RESUME_STREAM: enter full screen
            // once the window and a stream exist, so it can be verified headlessly.
            if ProcessInfo.processInfo.environment["IPTV_FULLSCREEN"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        } catch {
            banner = error.localizedDescription
            statusLine = "Couldn’t load channels"
        }
    }

    /// Movies and TV shows, loaded the same way live categories/streams are but never allowed to
    /// fail loudly: `get_vod_streams` and `get_series` are standard Xtream actions, but not every
    /// panel carries VOD or series on every account, and a 404 or an empty array here must leave
    /// the sidebar exactly as it was for a live-only subscription rather than raising a banner
    /// over something the user never asked this provider for.
    ///
    /// `requestedClient` is the client this fetch was started FOR, captured at the call site
    /// rather than read fresh from `self.client` — a fire-and-forget fetch that reads `self.client`
    /// at the end instead of the start can finish after the user has switched to a different
    /// subscription (switchSubscription's own connect() replaces `self.client`) and overwrite the
    /// NEW provider's movies/series with the OLD one's. The identity check below is what actually
    /// prevents that, not just capturing the parameter.
    public func loadVODCatalog(for requestedClient: XtreamClient? = nil) async {
        guard let requestedClient = requestedClient ?? client else { return }
        async let vodCatsTask: [ChannelCategory] = (try? await requestedClient.vodCategories()) ?? []
        async let vodStreamsTask: [VODStream] = (try? await requestedClient.vodStreams()) ?? []
        async let seriesCatsTask: [ChannelCategory] = (try? await requestedClient.seriesCategories()) ?? []
        async let seriesListTask: [SeriesSummary] = (try? await requestedClient.seriesList()) ?? []
        let vodCats = await vodCatsTask
        let vods = await vodStreamsTask
        let seriesCats = await seriesCatsTask
        let series = await seriesListTask

        guard client === requestedClient else {
            writeGuideDiagnostics("vod catalog: discarded — a different subscription is active now")
            return
        }
        self.vodCategories = vodCats.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.vodStreams = vods
        self.seriesCategories = seriesCats.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.seriesList = series
        recomputeFilter()
        writeGuideDiagnostics("vod catalog: \(vods.count) movies in \(vodCats.count) categories, "
            + "\(series.count) series in \(seriesCats.count) categories")

        // Automation seam, same shape as IPTV_RESUME_STREAM: play a specific movie by its VOD
        // stream id on launch, so the movie playback path can be verified without clicking
        // anything — there is no accessibility-driven way to click a sidebar row headlessly.
        if let raw = ProcessInfo.processInfo.environment["IPTV_PLAY_MOVIE"], let wanted = Int(raw) {
            if let movie = vods.first(where: { $0.streamID == wanted }) {
                writeGuideDiagnostics("resume: movie \(wanted) matched \(movie.name)")
                Task { @MainActor in playMovie(movie) }
            } else {
                writeGuideDiagnostics("resume: movie \(wanted) not in the VOD catalogue")
            }
        }
    }

    /// Everything about the current session except the credential itself — shared by `signOut()`
    /// (which also forgets the credential) and `switchSubscription` (which must NOT forget it;
    /// the subscription being left is still saved in the library for next time).
    private func resetSessionState() {
        stopPlayback()
        client = nil
        account = nil
        categories = []
        channels = []
        filteredChannels = []
        vodCategories = []
        vodStreams = []
        seriesCategories = []
        seriesList = []
        filteredVOD = []
        filteredSeries = []
        guideProgrammes = [:]
        guideChannels = []
        epgProgrammeCount = 0
        guideStatus = "No guide loaded yet."
        selectedChannel = nil
        selectedCategoryID = AppModel.allCategoryID
        searchText = ""
        nowPlayingTitle = ""
        nowPlayingDetail = ""
        banner = nil
        parentalUnlocked = false
    }

    /// Disconnects the current session only. The subscription itself — its Keychain item, its
    /// row in Manage Subscriptions — is untouched, so signing back into it is one tap, not
    /// re-typing a server, username and password. This used to also delete the subscription
    /// outright, which did the exact same irreversible thing the trash-icon Remove flow asks an
    /// explicit confirmation for, silently; Remove is now the only path that forgets a login for
    /// good.
    public func signOut() {
        resetSessionState()
        if activeSubscriptionID != nil {
            var index = library.load()
            index.activePlaylistID = nil
            library.save(index)
        }
        activeSubscriptionID = nil
        statusLine = "Not signed in"
        phase = .signedOut
    }

    // MARK: - Subscriptions (switching between saved providers)

    /// First run of this feature: if the library is empty but a legacy single "primary"
    /// credential exists, wrap it as the library's first playlist — non-destructively. The
    /// original "primary" item is left exactly where it was, so if anything here goes wrong the
    /// app still starts exactly as it did before this feature existed. Every sign-in since this
    /// shipped already creates its own playlist immediately (see `signIn`), so in practice this
    /// only ever matters once, for an install that signed in before this feature existed.
    private func migrateLegacyPrimaryIntoLibrary(_ index: inout LibraryIndex) {
        guard index.playlists.isEmpty, let legacy = CredentialStore.load() else { return }
        let host = XtreamClient.normalizeServer(legacy.server)
        let playlist = Playlist(id: PlaylistID(), name: displayName(forHost: host),
                                kind: .xtream(host: host))
        do {
            try CredentialStore.save(legacy, account: playlist.id.keychainAccount)
        } catch {
            writeGuideDiagnostics("subscription migration failed: \(error.localizedDescription)")
            return
        }
        index.playlists = [playlist]
        index.activePlaylistID = playlist.id
        library.save(index)
    }

    /// Validates by actually signing in — a login that doesn't work is never silently saved.
    /// Leaves whatever is currently connected alone; call `switchSubscription` to make this one
    /// live. Returns the new subscription's id on success. (Returning the id directly — rather
    /// than having the caller look the row back up by name afterward — is deliberate: a caller
    /// that re-finds "the one just added" by matching the raw name it passed in can match the
    /// wrong existing row, or none at all, the moment the name gets trimmed or defaulted.)
    public func addSubscription(name: String, server: String, username: String,
                                password: String) async -> AddSubscriptionOutcome {
        let credentials = Credentials(server: server, username: username, password: password)
        do {
            _ = try await XtreamClient(credentials: credentials).login()
        } catch {
            return .failure(error.localizedDescription)
        }
        let host = XtreamClient.normalizeServer(server)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: PlaylistID(),
                                name: trimmedName.isEmpty ? displayName(forHost: host) : trimmedName,
                                kind: .xtream(host: host))
        do {
            try CredentialStore.save(credentials, account: playlist.id.keychainAccount)
        } catch {
            return .failure(error.localizedDescription)
        }
        var index = library.load()
        index.add(playlist)
        library.save(index)
        subscriptions = index.orderedPlaylists
        return .success(playlist.id)
    }

    /// Connects to a different saved subscription. The new login is validated FIRST, before
    /// anything about the current session is touched — this used to tear the current connection
    /// down up front, so a switch that failed (an expired login, a provider that happened to be
    /// down — not rare for this project's own provider) left the user looking at a bare sign-in
    /// screen with no way back to any saved subscription without quitting and relaunching. Reuses
    /// the client it just validated with rather than logging in again through `connect()`.
    public func switchSubscription(_ id: PlaylistID) async {
        guard id != activeSubscriptionID else { return }
        guard let playlist = subscriptions.first(where: { $0.id == id }) else { return }
        guard let credentials = CredentialStore.load(account: playlist.id.keychainAccount) else {
            banner = "No saved login found for \(playlist.name) — remove it and add it again."
            return
        }
        let candidate = XtreamClient(credentials: credentials)
        let newAccount: Account
        do {
            newAccount = try await candidate.login()
        } catch {
            banner = "Couldn't switch to \(playlist.name): \(error.localizedDescription)"
            return
        }
        resetSessionState()
        await activate(candidate, account: newAccount, playlistID: id)
    }

    /// Forgets one saved subscription for good: its Keychain item and its row in Manage
    /// Subscriptions. Disconnects first if it's the one currently active — unlike `signOut`,
    /// which never deletes anything, this is the explicit, confirmed-by-the-caller "forget it"
    /// action, so it's allowed to.
    public func removeSubscription(_ id: PlaylistID) {
        guard let playlist = subscriptions.first(where: { $0.id == id }) else { return }
        if id == activeSubscriptionID {
            resetSessionState()
            activeSubscriptionID = nil
            statusLine = "Not signed in"
            phase = .signedOut
        }
        CredentialStore.delete(account: playlist.id.keychainAccount)
        var index = library.load()
        index.remove(id)
        if index.activePlaylistID == id { index.activePlaylistID = nil }
        library.save(index)
        subscriptions = index.orderedPlaylists
    }

    /// Automation seam, same shape as IPTV_RESUME_STREAM / IPTV_PLAY_MOVIE: exercises
    /// addSubscription + switchSubscription end to end on launch, so the multi-subscription
    /// switcher can be verified without clicking anything.
    /// `IPTV_ADD_SUBSCRIPTION="name|server|username|password"`.
    public func addAndSwitchSubscriptionFromEnvironmentIfRequested() async {
        guard let raw = ProcessInfo.processInfo.environment["IPTV_ADD_SUBSCRIPTION"] else { return }
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 4 else {
            writeGuideDiagnostics("subscription seam: IPTV_ADD_SUBSCRIPTION needs 4 '|'-separated fields, got \(parts.count)")
            return
        }
        let (name, server, username, password) = (parts[0], parts[1], parts[2], parts[3])
        writeGuideDiagnostics("subscription seam: adding \(name)")
        switch await addSubscription(name: name, server: server, username: username, password: password) {
        case .failure(let message):
            writeGuideDiagnostics("subscription seam: add failed — \(message)")
        case .success(let id):
            writeGuideDiagnostics("subscription seam: added, now \(subscriptions.count) saved")
            await switchSubscription(id)
            writeGuideDiagnostics("subscription seam: switched, active=\(activeSubscriptionID == id) "
                + "channels=\(channels.count)")
        }
    }

    // MARK: - Filtering

    /// One pass over the catalog whenever something that changes the visible set
    /// changes — never per render.
    public func recomputeFilter() {
        var result = channels

        let hidden = Set(settings.data.hiddenCategoryIDs)
        if !hidden.isEmpty { result = result.filter { !hidden.contains($0.categoryID ?? "") } }

        if settings.data.parentalEnabled && !parentalUnlocked && !lockedCategoryIDs.isEmpty {
            result = result.filter { !lockedCategoryIDs.contains($0.categoryID ?? "") }
        }

        switch selectedCategoryID {
        case CatalogSelection.allChannelsID:
            break
        case CatalogSelection.favouritesID:
            let favs = Set(favourites.data.streamIDs)
            result = result.filter { favs.contains($0.streamID) }
        case CatalogSelection.recentsID:
            let order = favourites.data.recentStreamIDs
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            result = result.filter { rank[$0.streamID] != nil }
                .sorted { (rank[$0.streamID] ?? .max) < (rank[$1.streamID] ?? .max) }
        default:
            result = result.filter { $0.categoryID == selectedCategoryID }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        if settings.data.sortOrder == .name {
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        filteredChannels = result

        // A view-layer bug once hid exactly here: state changed, nothing redrew, and the log was
        // silent either way. Recording what the filter did means "I clicked and nothing happened"
        // can be answered from evidence instead of from the screen.
        if selectedCategoryID != lastLoggedFilterCategory || result.count != lastLoggedFilterCount {
            lastLoggedFilterCategory = selectedCategoryID
            lastLoggedFilterCount = result.count
            writeGuideDiagnostics("filter: category=\(selectedCategoryID) -> \(result.count) channels")
        }

        // Movies and series share the sidebar's one search field but never share a category
        // namespace with live or with each other — a provider numbers each catalog from 1, so
        // "VOD:" / "SERIES:" prefixes on the selection are what keep a live category id from
        // accidentally matching a VOD one. Cached for the same reason filteredChannels is: a
        // computed property re-filtering 36,000 movies on every render is the exact bug that
        // made filteredChannels a cache in the first place.
        if selectedCategoryID.hasPrefix(CatalogSelection.vodPrefix) {
            let categoryID = String(selectedCategoryID.dropFirst(CatalogSelection.vodPrefix.count))
            var vod = categoryID == CatalogSelection.allSuffix
                ? vodStreams : vodStreams.filter { $0.categoryID == categoryID }
            if !trimmed.isEmpty { vod = vod.filter { $0.name.localizedCaseInsensitiveContains(trimmed) } }
            filteredVOD = vod.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            filteredSeries = []
        } else if selectedCategoryID.hasPrefix(CatalogSelection.seriesPrefix) {
            let categoryID = String(selectedCategoryID.dropFirst(CatalogSelection.seriesPrefix.count))
            var series = categoryID == CatalogSelection.allSuffix
                ? seriesList : seriesList.filter { $0.categoryID == categoryID }
            if !trimmed.isEmpty { series = series.filter { $0.name.localizedCaseInsensitiveContains(trimmed) } }
            filteredSeries = series.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            filteredVOD = []
        } else {
            filteredVOD = []
            filteredSeries = []
        }
    }

    public var favouriteCount: Int { favourites.data.streamIDs.count }

    /// Switches the icon-rail tab and lands on that section's "everything" view — "All
    /// Channels", "All Movies" or "All TV Shows" — rather than leaving the previous section's
    /// category id selected while a different section's list is on screen.
    public func selectSidebarSection(_ section: SidebarSection) {
        sidebarSection = section
        switch section {
        case .live: selectedCategoryID = AppModel.allCategoryID
        case .movies: selectedCategoryID = CatalogSelection.vodAllID
        case .series: selectedCategoryID = CatalogSelection.seriesAllID
        }
    }

    public func categoryName(for id: String) -> String {
        categories.first { $0.id == id }?.name ?? "Channels"
    }

    private func rebuildLockedCategories() {
        guard settings.data.parentalEnabled else {
            lockedCategoryIDs = []
            lockedChannelCount = 0
            return
        }
        lockedCategoryIDs = Set(categories.filter { settings.isLocked(category: $0.name) }.map(\.id))
        lockedChannelCount = channels.filter { lockedCategoryIDs.contains($0.categoryID ?? "") }.count
    }

    /// Called when the settings that affect the visible set change.
    public func settingsChanged() {
        rebuildLockedCategories()
        recomputeFilter()
        rebuildGuideProgrammes()
    }

    // MARK: - Guide

    public func loadGuide(force: Bool) async {
        guard let client, !isLoadingGuide else { return }
        if !force && !guideProgrammes.isEmpty { return }
        isLoadingGuide = true
        defer { isLoadingGuide = false }

        guard let cacheURL = guideCacheURL else {
            guideStatus = "Guide unavailable — no portal configured"
            return
        }

        // A fresh cache beats a re-download: the full guide runs to tens of megabytes
        // and the refresh interval is the user's stated tolerance for staleness.
        let refreshInterval = TimeInterval(max(settings.data.guideRefreshMinutes, 1) * 60)
        var cacheIsFresh = false
        if !force,
           let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date,
           let size = attributes[.size] as? Int, size > 0,
           Date().timeIntervalSince(modified) < refreshInterval {
            cacheIsFresh = true
            guideStatus = "Reading the guide cached \(Int(Date().timeIntervalSince(modified) / 60)) min ago…"
        }

        if !cacheIsFresh {
            guideStatus = "Downloading the guide…"
            do {
                guideBytes = try await client.downloadXMLTVFile(to: cacheURL)
            } catch {
                // A stale guide that parses beats an empty grid, so fall back to
                // whatever is on disk and say so rather than blanking out.
                let cached = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)) != nil
                guideStatus = cached
                    ? "Guide download failed (\(error.localizedDescription)) — using the cached copy"
                    : "Guide download failed: \(error.localizedDescription)"
                if !cached { return }
            }
        }

        do {
            let data = try Data(contentsOf: cacheURL, options: .mappedIfSafe)
            let megabytes = Double(data.count) / 1_048_576
            guideBytes = data.count
            // Drop anything that finished more than three hours ago: providers
            // publish a full fortnight and we only ever draw a few hours.
            let cutoff = Date().addingTimeInterval(-3 * 3600)
            let outcome = try await Task.detached(priority: .utility) {
                try XMLTVParser.parseDetailed(data: data, skipEndedBefore: cutoff)
            }.value
            let parsed = outcome.programmes
            guideParseStats = outcome.stats

            epgProgrammeCount = parsed.values.reduce(0) { $0 + $1.count }
            rawEPG = parsed

            // Published on another clock? Correct it before drawing, not after.
            guideAlignmentNote = ""
            if settings.data.autoAlignGuide {
                let detected = GuideAlignment.detectOffset(programmes: parsed,
                                                          channelIDs: guideChannelKeys)
                if detected != 0 {
                    settings.data.epgOffsetMinutes = detected
                    guideAlignmentNote = Self.shiftDescription(detected)
                }
            }

            rebuildGuideProgrammes()
            updateGuideSpan()
            let matched = guideProgrammes.count
            guideStatus = String(format: "%.1f MB%@ • %d programmes • %d of %d channels matched",
                                 megabytes, cacheIsFresh ? " (cached)" : "",
                                 epgProgrammeCount, matched, channels.count)
            if !guideAlignmentNote.isEmpty { guideStatus += " • " + guideAlignmentNote }
            // guideStatus rides on every diagnostics line, so counting the discards here means a
            // provider whose stamps stop parsing shows up as a number rather than as a guide that
            // is mysteriously thinner than it used to be.
            if outcome.stats.droppedTotal > 0 {
                guideStatus += " • discarded \(outcome.stats.droppedBadTimestamps) bad timestamps, "
                    + "\(outcome.stats.droppedEnded) already ended, "
                    + "\(outcome.stats.droppedNoChannel) with no channel"
            }
        } catch {
            guideStatus = "Guide unavailable: \(error.localizedDescription)"
        }
    }

    /// Draws a guide straight from an XMLTV file on disk, with channels made from that
    /// guide's own channel ids: no provider, no credentials, no network.
    /// `IPTV_GUIDE_FILE=/path/to/xmltv.xml`.
    ///
    /// This exists because the guide's layout could not be diagnosed through a signed-in
    /// session without paying a keychain authorisation for every build — the app's
    /// ad-hoc signature makes each build a stranger to the keychain. Here the guide
    /// renders with real titles and real timing and nothing guarding the door. Unset,
    /// the app behaves exactly as it did before.
    private func loadGuideFixture(from path: String) async {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            let cutoff = Date().addingTimeInterval(-3 * 3600)
            let parsed = try await Task.detached(priority: .utility) {
                try XMLTVParser.parse(data: data, skipEndedBefore: cutoff)
            }.value

            let identifiers = parsed.keys.sorted()
            channels = identifiers.enumerated().map { index, identifier in
                Channel(streamID: 900_000 + index,
                        number: index + 1,
                        name: identifier,
                        epgChannelID: identifier)
            }
            categories = []
            rawEPG = parsed
            epgProgrammeCount = parsed.values.reduce(0) { $0 + $1.count }

            // Same path as a real load, so a fixture reproduces the real rendering.
            guideAlignmentNote = ""
            if settings.data.autoAlignGuide {
                let detected = GuideAlignment.detectOffset(programmes: parsed,
                                                          channelIDs: guideChannelKeys)
                if detected != 0 {
                    settings.data.epgOffsetMinutes = detected
                    guideAlignmentNote = Self.shiftDescription(detected)
                }
            }
            // The previous live session's category selection persists, and no generated
            // channel belongs to it — which leaves the visible list empty and sends the
            // guide down its "nothing in this window" branch. Start from everything.
            selectedCategoryID = Self.allCategoryID
            searchText = ""

            rebuildGuideProgrammes()
            updateGuideSpan()
            guideStatus = "fixture • \(epgProgrammeCount) programmes • "
                + "\(guideProgrammes.count) of \(channels.count) channels matched"
            statusLine = "Fixture guide from \(URL(fileURLWithPath: path).lastPathComponent)"
            phase = .ready
            writeGuideDiagnostics("fixture guide loaded")
        } catch {
            statusLine = "Fixture guide unreadable: \(error.localizedDescription)"
            phase = .signedOut
        }
    }

    /// Appends a one-line report of the guide's state to `diagnostics.log` beside the
    /// cached guide. A screenshot cannot be trusted to show a caption that may be
    /// truncated, too faint to read, or simply not laid out — and the guide's own
    /// header is exactly the thing under suspicion — so the numbers get written down.
    public func writeGuideDiagnostics(_ note: String) {
        // Deliberately independent of the client. This is called from bootstrap, before
        // sign-in, where there is no client yet — and a dependency on one silently threw
        // away exactly the messages that mattered most.
        guard let folder = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JabcorpTV", isDirectory: true) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let summary = "[\(stamp)] \(note) | channels=\(channels.count) "
            + "categories=\(categories.count) bytes=\(guideBytes) epg=\(epgProgrammeCount) "
            + "guideChannels=\(guideChannels.count) programmeSets=\(guideProgrammes.count) "
            + "span=\(guideSpanText.isEmpty ? "none" : guideSpanText) "
            + "offset=\(settings.data.epgOffsetMinutes) "
            + "window=\(settings.data.guideMinutesBack)back/\(settings.data.guideHoursAhead)ahead "
            + "loading=\(isLoadingGuide) status=\(guideStatus)"
        let url = folder.appendingPathComponent("diagnostics.log")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let payload = Data((summary + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: url)
            }
        } catch {
            print("diagnostics write failed: \(error.localizedDescription)")
        }
    }

    /// A one-line readout of the guide's internal state, surfaced in the toolbar.
    /// The guide's own header is where this belongs, but the header is inside the
    /// view that is misbehaving, so this is the only readout that can be trusted
    /// while diagnosing why a grid draws nothing.
    public var guideDiagnostic: String {
        let span = guideSpanText.isEmpty ? "no-span" : guideSpanText
        return "guide ch\(guideChannels.count) pg\(guideProgrammes.count) "
            + "epg\(epgProgrammeCount) span \(span) off\(settings.data.epgOffsetMinutes) "
            + "\(isLoadingGuide ? "loading" : "ready") \(String(guideStatus.prefix(34)))"
    }

    /// The XMLTV channel ids the catalogue actually points at — the only set worth
    /// aligning against, and far cheaper to scan than the whole guide.
    private var guideChannelKeys: [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for channel in channels {
            guard let key = channel.epgChannelID, !key.isEmpty, rawEPG[key] != nil else { continue }
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    /// Plain wording for a detected shift.
    static func shiftDescription(_ minutes: Int) -> String {
        let hours = Double(minutes) / 60
        let amount = abs(hours) < 1
            ? "\(abs(minutes)) min"
            : String(format: "%g h", abs(hours))
        return "auto-aligned \(amount) \(minutes < 0 ? "back" : "forward") to match now"
    }

    /// Re-measure and apply the shift on demand, for the "Align to now" button on an
    /// otherwise unexplained empty grid.
    public func alignGuideToNow() {
        let detected = GuideAlignment.detectOffset(programmes: rawEPG, channelIDs: guideChannelKeys)
        settings.data.epgOffsetMinutes = detected
        rebuildGuideProgrammes()
        updateGuideSpan()
        guideAlignmentNote = detected == 0 ? "no shift needed" : Self.shiftDescription(detected)
        guideStatus = guideAlignmentNote
    }

    /// Manual nudge for when the measured alignment is not quite what the guide needs.
    public func nudgeGuideShift(byMinutes minutes: Int) {
        settings.data.epgOffsetMinutes += minutes
        rebuildGuideProgrammes()
        updateGuideSpan()
        guideAlignmentNote = Self.shiftDescription(settings.data.epgOffsetMinutes)
        guideStatus = guideAlignmentNote
    }

    public func clearGuideShift() {
        settings.data.epgOffsetMinutes = 0
        guideAlignmentNote = ""
        rebuildGuideProgrammes()
        updateGuideSpan()
        guideStatus = "Guide shift reset to none"
    }

    /// The actual span of the guide we hold. When the grid looks empty this is what
    /// tells the user whether the data is missing or merely out of the window.
    private func updateGuideSpan() {
        var earliest: Date?
        var latest: Date?
        for (_, list) in guideProgrammes {
            for programme in list {
                if earliest == nil || programme.start < earliest! { earliest = programme.start }
                if latest == nil || programme.stop > latest! { latest = programme.stop }
            }
        }
        guard let from = earliest, let to = latest else {
            guideSpanText = ""
            return
        }
        // Both ends carry their date when the span crosses a day. Formatting only the start's
        // weekday and the end's clock turned a genuine 26-day span into "Fri 00:00-02:00", which
        // reads as two hours — and the empty state then quoted that misreading back as fact,
        // which sent a hunt after a provider clock fault that did not exist.
        let head = DateFormatter()
        let tail = DateFormatter()
        // Pinned locale and zone. An unpinned formatter follows the system's regional settings and
        // zone, and this guide crosses a DST boundary on 1 November, so the same instant printed an
        // hour earlier than it is. That is enough to make a coherent span read as incoherent, which
        // is the failure this whole episode was about.
        for formatter in [head, tail] {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        if gregorian.isDate(from, inSameDayAs: to) {
            head.dateFormat = "HH:mm"
            tail.dateFormat = "HH:mm"
        } else {
            head.dateFormat = "EEE d MMM HH:mm"
            tail.dateFormat = "EEE d MMM HH:mm"
        }
        guideSpanText = "\(head.string(from: from))–\(tail.string(from: to))"
    }

    private var rawEPG: [String: [XMLTVProgramme]] = [:]
    /// Size of the guide file on disk, and the span of the data we ended up holding,
    /// so the guide can explain itself instead of just looking empty.
    @Published public private(set) var guideBytes = 0
    /// What the last guide parse kept and threw away. Zero on a healthy provider; the point is
    /// that a change is countable rather than invisible.
    @Published public private(set) var guideParseStats = XMLTVParseStats()
    @Published public private(set) var guideSpanText = ""
    @Published public var guideAlignmentNote = ""

    /// The downloaded guide is cached here and reused until the refresh interval
    /// elapses. Keyed by portal so switching providers cannot mix guides up.
    public var guideCacheURL: URL? {
        guard let client else { return nil }
        let key = client.base.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-",
                                                   options: .regularExpression)
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appendingPathComponent("JabcorpTV", isDirectory: true)
            .appendingPathComponent("guide-\(key).xml")
    }

    /// Applies the timezone offset once, keyed by stream id, so the guide and the
    /// channel list can look a programme up in O(1) without re-mapping per render.
    public func rebuildGuideProgrammes() {
        var byStream: [Int: [XMLTVProgramme]] = [:]
        let offset = TimeInterval(settings.data.epgOffsetMinutes * 60)
        for channel in channels {
            guard let key = channel.epgChannelID, let list = rawEPG[key], !list.isEmpty else { continue }
            let shifted = offset == 0 ? list : list.map {
                XMLTVProgramme(channelID: $0.channelID, title: $0.title, detail: $0.detail,
                               start: $0.start.addingTimeInterval(offset),
                               stop: $0.stop.addingTimeInterval(offset))
            }
            byStream[channel.streamID] = shifted.sorted { $0.start < $1.start }
        }
        guideProgrammes = byStream
        guideChannels = filteredChannels.filter { byStream[$0.streamID] != nil }
    }

    public func programmes(for channel: Channel) -> [XMLTVProgramme] {
        guideProgrammes[channel.streamID] ?? []
    }

    /// A per-channel breakdown of EPG matching, for diagnosing "the header says data is loaded
    /// but the grid looks empty" reports — one specific question answered precisely (does this
    /// channel's own epg_channel_id match a key in the raw guide, and did that survive into
    /// guideProgrammes) rather than another guess. Deliberately not wired to run continuously or
    /// over a large selection; GuideView calls it only for a small category.
    public func epgMatchDebugDump(for channelsToCheck: [Channel]) -> String {
        let now = Date()
        return channelsToCheck.map { channel in
            let key = channel.epgChannelID ?? "(none)"
            let rawCount = channel.epgChannelID.flatMap { rawEPG[$0]?.count } ?? -1
            let matched = guideProgrammes[channel.streamID] ?? []
            let firstWindow = matched.first.map {
                "\(GuideFormat.time($0.start))-\(GuideFormat.time($0.stop))"
            } ?? "none"
            // The one programme `isLive`/`isPast` in the guide row would actually pick for
            // "now" — this is what decides whether a block renders as live, replayable or
            // disabled, so it answers "is the grid's own live/catch-up state correct" directly
            // rather than requiring it to be read off a screenshot.
            let live = matched.first { $0.start <= now && now < $0.stop }
            let liveText = live.map { "\(GuideFormat.range($0.start, $0.stop)) \($0.title)" } ?? "none"
            return "\(channel.name)[\(channel.streamID)] epgKey=\(key) rawEPG=\(rawCount) "
                + "matched=\(matched.count) first=\(firstWindow) hasArchive=\(channel.hasArchiveFlag) "
                + "archiveDays=\(channel.archiveDays) nowProgramme=\(liveText)"
        }.joined(separator: " || ")
    }

    public func currentProgramme(for channel: Channel) -> XMLTVProgramme? {
        guard let list = guideProgrammes[channel.streamID] else { return nil }
        let now = Date()
        return list.first { $0.start <= now && now < $0.stop }
    }

    public func nextProgramme(for channel: Channel) -> XMLTVProgramme? {
        guard let list = guideProgrammes[channel.streamID] else { return nil }
        let now = Date()
        return list.first { $0.start > now }
    }

    public func toggleFavourite(_ channel: Channel) {
        favourites.toggle(channel.streamID)
        recomputeFilter()
    }

    // MARK: - Playback

    /// Channels the provider says carry an archive. It is worth counting rather than
    /// assuming: a subscription can advertise catch-up on every channel, on none, or on
    /// a handful, and the app should say which.
    public var catchUpChannelCount: Int { channels.filter(\.hasArchive).count }

    /// Which categories actually hold channels. Providers hand out categories they carry
    /// nothing in, and selecting one is a dead end.
    public var categoryIDsWithChannels: Set<String> {
        Set(channels.compactMap { $0.categoryID })
    }
    public var catchUpSupported: Bool { catchUpChannelCount > 0 }

    public func play(_ channel: Channel) {
        guard let client else {
            // A diagnostics line is not feedback. In fixture mode, or signed out, clicking a
            // channel produced nothing on screen at all — which reads as a broken click.
            banner = "Not connected to a provider — \(channel.name) cannot be played yet."
            writeGuideDiagnostics("play: no client yet, cannot open \(channel.name)")
            return
        }
        let format = Self.formatCandidates(preferred: settings.data.preferredFormat)[0]
        guard let url = client.liveURL(streamID: channel.streamID, format: format) else {
            banner = "Couldn't build a \(format) link for \(channel.name)."
            writeGuideDiagnostics("play: could not build a \(format) URL for \(channel.name)")
            return
        }
        writeGuideDiagnostics("play: opening \(channel.name) as \(format)")
        triedFormats = [format]
        formatRefusals = [:]
        formatAttempts = [:]
        nextProbeAt = .distantPast
        startPlayback(url: url, channel: channel, catchUp: nil, format: format)
    }

    /// Past programmes play from the archive when the channel carries one; anything live
    /// or future tunes the live stream — except a programme already under way on a
    /// channel that can rewind, which starts from its beginning when the user asks for it.
    public func playProgramme(_ programme: XMLTVProgramme, on channel: Channel) {
        let now = Date()
        if programme.stop < now {
            guard channel.hasArchive else {
                banner = "Catch-up isn't available on \(channel.name) — this provider "
                    + "advertises no archive on it."
                return
            }
            playArchive(programme, on: channel)
        } else if programme.start <= now, channel.hasArchive,
                  settings.data.startLiveFromBeginning {
            playArchive(programme, on: channel)
        } else {
            play(channel)
        }
    }

    /// Plays a programme from the provider's archive. The start stamp goes out in the panel's
    /// own timezone (see `XtreamClient.catchUpURL`); `connect()` sets `client.panelTimeZone`
    /// from the account's `server_info.timezone` as soon as login succeeds.
    private func playArchive(_ programme: XMLTVProgramme, on channel: Channel) {
        let minutes = max(1, Int(programme.stop.timeIntervalSince(programme.start) / 60))
        let format = Self.formatCandidates(preferred: settings.data.preferredFormat)[0]
        guard let client,
              let url = client.catchUpURL(streamID: channel.streamID,
                                          start: programme.start,
                                          durationMinutes: minutes,
                                          format: format) else { return }
        triedFormats = [format]
        formatRefusals = [:]
        formatAttempts = [:]
        nextProbeAt = .distantPast
        startPlayback(url: url, channel: channel, catchUp: (programme.start, programme.stop),
                      format: format)
    }

    public func backToLive() {
        guard let channel = selectedChannel else { return }
        play(channel)
    }

    // MARK: - VOD / Series playback

    public func playMovie(_ movie: VODStream) {
        guard let client,
              let url = client.vodURL(streamID: movie.streamID, ext: movie.containerExtension)
        else {
            banner = "Couldn't build a link for \(movie.name)."
            return
        }
        writeGuideDiagnostics("play: opening movie \(movie.name)")
        startMediaPlayback(url: url, title: movie.name)
    }

    public func playEpisode(_ episode: SeriesEpisode, of series: SeriesSummary) {
        guard let client,
              let url = client.episodeURL(episodeID: episode.episodeID, ext: episode.containerExtension)
        else {
            banner = "Couldn't build a link for \(series.name) — \(episode.title)."
            return
        }
        let title = "\(series.name) — S\(episode.season)E\(episode.episodeNumber) \(episode.title)"
        writeGuideDiagnostics("play: opening episode \(title)")
        startMediaPlayback(url: url, title: title)
    }

    /// `get_series_info` on demand — fetching every series' episode list up front alongside
    /// `loadVODCatalog()` would be thousands of extra requests nothing has asked for yet.
    public func fetchEpisodes(seriesID: Int) async -> [Int: [SeriesEpisode]] {
        guard let client else { return [:] }
        return (try? await client.seriesEpisodes(seriesID: seriesID)) ?? [:]
    }

    private func startMediaPlayback(url: URL, title: String) {
        if settings.data.stopPreviousOnZap {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        // A movie or episode is never a Channel, so it clears the live-channel selection rather
        // than reusing it — the player pane tells the two states apart by `nowPlayingIsMedia`,
        // not by trying to make one Channel value mean both things.
        selectedChannel = nil
        nowPlayingTask?.cancel()
        isCatchUp = false
        catchUpRange = ""
        nowPlayingIsMedia = true
        nowPlayingTitle = title
        nowPlayingDetail = "Connecting…"
        playbackFailed = false
        banner = nil
        lastMediaRequest = (url, title)
        startMediaItem(url: url, title: title, attempt: 1)
    }

    /// The movie/episode counterpart of `startItem`. Deliberately simpler: there is exactly one
    /// URL (the provider already named its own container extension), so a refusal just retries
    /// that same URL a bounded number of times instead of climbing a format ladder that does not
    /// apply here, and a stream that stays reachable-but-slow gets the same bounded deadline
    /// extension `startItem` was just fixed to use, rather than silently giving up on it.
    private func startMediaItem(url: URL, title: String, attempt: Int) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        mediaStatusTask?.cancel()
        mediaStatusTask = Task { @MainActor [weak self] in
            let start = Date()
            var deadline = start.addingTimeInterval(45)
            var stallExtensions = 0
            let maxStallExtensions = 4
            while true {
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if Task.isCancelled { return }
                    guard let self, self.player.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.playbackFailed = false
                        self.nowPlayingDetail = "Playing"
                        self.writeGuideDiagnostics("media playback ready: \(title) (attempt \(attempt))")
                        return
                    case .failed:
                        let why = item.error?.localizedDescription ?? "the provider refused the stream"
                        self.writeGuideDiagnostics("media playback failed: \(title) attempt \(attempt): \(why)")
                        if attempt < Self.attemptsPerFormat {
                            self.nowPlayingDetail = "Retrying… (\(attempt)/\(Self.attemptsPerFormat))"
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if Task.isCancelled { return }
                            self.startMediaItem(url: url, title: title, attempt: attempt + 1)
                            return
                        }
                        self.reportMediaUnplayable(title: title, detail: why)
                        return
                    default:
                        continue
                    }
                }
                guard let self, self.player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    playbackFailed = false
                    nowPlayingDetail = "Playing"
                    writeGuideDiagnostics("media playback ready: \(title) (slow start, attempt \(attempt))")
                    return
                }
                nowPlayingDetail = "Still connecting…"
                let elapsed = Int(Date().timeIntervalSince(start).rounded())
                let verdict = await probeStream(url)
                // The probe can run up to its own ~12s timeout; by the time it resolves the user
                // may have switched to something else entirely. Without this, a stale probe
                // resolving late could write "Playing"/a retry/an unplayable banner for a title
                // that isn't even on screen anymore — the same class of cross-stream clobber the
                // identity guard above this block already exists to prevent, just not carried
                // past the probe await the way it is before every other state write in this loop.
                if Task.isCancelled || self.player.currentItem !== item { return }
                switch verdict {
                case .playable:
                    stallExtensions += 1
                    writeGuideDiagnostics("media playback: \(title) still not playing after \(elapsed)s — "
                        + "provider is serving it (reachable, just slow), still waiting "
                        + "(\(stallExtensions)/\(maxStallExtensions))")
                    if stallExtensions >= maxStallExtensions {
                        reportMediaUnplayable(title: title, detail: "the provider never finished connecting "
                            + "(it kept answering, but the player never started)")
                        return
                    }
                    deadline = Date().addingTimeInterval(20)
                    continue
                case .inconclusive(let why):
                    stallExtensions += 1
                    writeGuideDiagnostics("media playback: \(title) still not playing after \(elapsed)s — "
                        + "probe inconclusive: \(why), still waiting (\(stallExtensions)/\(maxStallExtensions))")
                    if stallExtensions >= maxStallExtensions {
                        reportMediaUnplayable(title: title, detail: "the provider never finished connecting "
                            + "(it kept answering, but the player never started)")
                        return
                    }
                    deadline = Date().addingTimeInterval(20)
                    continue
                case .refused(let why):
                    writeGuideDiagnostics("media playback: \(title) still not playing after \(elapsed)s — "
                        + "provider refused: \(why)")
                    reportMediaUnplayable(title: title, detail: why)
                    return
                }
            }
        }
    }

    private func reportMediaUnplayable(title: String, detail: String) {
        player.pause()
        playbackFailed = true
        nowPlayingDetail = "Not available from this provider"
        banner = "\(title) wouldn't start — \(detail)."
        writeGuideDiagnostics("media playback unavailable: \(title) — \(detail)")
    }

    public func retryMedia() {
        guard let request = lastMediaRequest else { return }
        playbackFailed = false
        nowPlayingDetail = "Connecting…"
        startMediaItem(url: request.url, title: request.title, attempt: 1)
    }

    public func openMediaInVLC() {
        guard let url = lastMediaRequest?.url else { return }
        openExternalPlayer(url: url)
    }

    /// What a provider is actually serving on a URL.
    enum StreamProbe: Equatable {
        case playable
        case refused(String)
        case inconclusive(String)
    }

    /// The container formats to try, preferred one first.
    static func formatCandidates(preferred: StreamFormat) -> [String] {
        preferred == .hls ? ["m3u8", "ts"] : ["ts", "m3u8"]
    }

    /// Asks the provider what it is serving, instead of believing a spinner.
    ///
    /// This exists because of a specific trap found in this owner's portal: it answers 404 for
    /// `.m3u8` on a channel it does not carry, and then answers **HTTP 200 with an HTML error page**
    /// for `.ts` on the same channel. Nothing that tests only the status code can tell that from
    /// success, so AVPlayer is handed a web page and sits at `.unknown` — which on screen is
    /// identical to a slow connect, and is why a dead channel used to sit behind "Connecting…"
    /// until the 45-second window expired.
    ///
    /// Reading a couple of kilobytes and looking at both the declared type and the first bytes does
    /// tell the difference. A refusal is reported only on definite evidence; anything else is
    /// inconclusive, because a stream that is merely slow must not be declared dead.
    func probeStream(_ url: URL) async -> StreamProbe {
        var request = URLRequest(url: url)
        request.setValue("IPTVMac/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        request.timeoutInterval = 12
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            let mime = (http?.mimeType ?? "").lowercased()

            // Two kilobytes is enough to classify, and stopping here means a live transport stream
            // is not downloaded to the end just to be asked whether it works.
            var head = Data()
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 2048 { break }
            }

            if code == 404 || code == 403 || code == 401 {
                return .refused("the provider answered HTTP \(code)")
            }
            if mime.contains("text/html") || head.first == UInt8(ascii: "<") {
                return .refused("the provider sent a web page, not video")
            }
            if !(200..<300).contains(code) {
                return .refused("the provider answered HTTP \(code)")
            }
            if head.isEmpty {
                return .refused("the provider sent an empty response")
            }
            return .playable
        } catch {
            // A timeout or transport error says nothing about whether the channel exists.
            return .inconclusive(error.localizedDescription)
        }
    }

    /// Moves to the next container format for the same channel. Returns false when there is none
    /// left, so the caller can report instead of guessing.
    private func advanceFormat(channel: Channel, catchUp: (Date, Date)?, from format: String) -> Bool {
        triedFormats.insert(format)
        guard let client,
              let next = Self.formatCandidates(preferred: settings.data.preferredFormat)
                  .first(where: { !triedFormats.contains($0) }) else { return false }

        let url: URL?
        if let catchUp {
            let minutes = max(1, Int(catchUp.1.timeIntervalSince(catchUp.0) / 60))
            url = client.catchUpURL(streamID: channel.streamID, start: catchUp.0,
                                    durationMinutes: minutes, format: next)
        } else {
            url = client.liveURL(streamID: channel.streamID, format: next)
        }
        guard let url else { return false }

        writeGuideDiagnostics("play: retrying \(channel.name) as \(next) — \(format) was refused \(Self.attemptsPerFormat) times")
        triedFormats.insert(next)
        // The replacement container starts with a clean slate and gets its own early check.
        formatAttempts[next] = 0
        nextProbeAt = .distantPast
        nowPlayingDetail = "Trying \(next == "m3u8" ? "HLS" : "MPEG-TS")…"
        lastPlaybackRequest = (url, channel, catchUp)
        startItem(url: url, channel: channel, catchUp: catchUp, format: next, attempt: 1)
        return true
    }

    /// The provider is not serving this channel in any container it offers. Saying so beats a
    /// spinner, and it beats offering "Play in VLC" — VLC would be refused by the same provider for
    /// the same reason, and asking the owner to test that is a wasted minute of their evening.
    private func reportUnplayable(_ channel: Channel, detail: String) {
        player.pause()
        playbackFailed = true
        nowPlayingDetail = "Not available from this provider"
        let reasons = formatRefusals.keys.sorted().compactMap { key in
            formatRefusals[key].map { "\(key): \($0)" }
        }.joined(separator: "; ")
        let why = reasons.isEmpty ? detail : reasons
        banner = "\(channel.name) wouldn't start — \(why). It answered the same way on every "
            + "container the app can ask for, \(Self.attemptsPerFormat) times each. This provider's "
            + "stream server does that intermittently, so try Retry before writing the channel off."
        writeGuideDiagnostics("playback unavailable: \(channel.name) — \(why)")
    }

    /// Records a channel as the one to resume, once it is genuinely playing.
    /// Clear the message without touching anything else. A banner with no way to dismiss it stays
    /// on screen long after it stopped being true.
    public func dismissBanner() { banner = nil }

    private func noteWatchedIfNeeded(_ channel: Channel) {
        favourites.noteWatched(channel.streamID)
        if selectedCategoryID == CatalogSelection.recentsID { recomputeFilter() }
    }

    private func startPlayback(url: URL, channel: Channel, catchUp: (Date, Date)?, format: String) {
        if settings.data.stopPreviousOnZap {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        selectedChannel = channel
        isCatchUp = catchUp != nil
        catchUpRange = catchUp.map { GuideFormat.range($0.0, $0.1) } ?? ""
        nowPlayingTitle = channel.name
        nowPlayingDetail = isCatchUp ? "Catch-up • \(catchUpRange)" : "Connecting…"
        playbackFailed = false
        // The previous failure is about the previous channel; leaving it up while a new one is
        // connecting reads as the new one having failed too.
        banner = nil
        lastPlaybackRequest = (url, channel, catchUp)
        startItem(url: url, channel: channel, catchUp: catchUp, format: format, attempt: 1)
        // "Last watched" is now recorded only once a channel is actually playing, in the ready
        // branch. Recording it here put a channel the provider had refused at the top of Recents,
        // so the next launch resumed straight back into the same failure.

        nowPlayingTask?.cancel()
        guard catchUp == nil else { return }
        nowPlayingTask = Task { [weak self] in
            await self?.describeNowPlaying(for: channel)
        }
    }

    /// AVPlayer reports a refused or undecodable stream only through the item's status, and
    /// silence looks exactly like a slow connect — which is how a dead stream sat behind a
    /// "Connecting…" label with nothing on screen to explain it. Watch the status, say what
    /// happened, and try once more: a panel can serve a request it refused a moment earlier.
    private func startItem(url: URL, channel: Channel, catchUp: (Date, Date)?,
                           format: String, attempt: Int) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        // Poll the item's status instead of observing it. The difference between "still
        // connecting" and "the provider refused it" only exists here, and polling is what the
        // standalone AVFoundation probes verified on this machine — a KVO registration alone
        // never delivered a single callback, which left the player silent about failure.
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            let start = Date()
            var deadline = start.addingTimeInterval(45)
            // How many times the 45s window has been extended because the provider keeps
            // answering "still here, just slow" rather than refusing outright. Capped so a
            // channel that never actually decodes still gets reported instead of spinning
            // "Still connecting…" forever — the exact failure mode this function exists to avoid.
            var stallExtensions = 0
            let maxStallExtensions = 4
            while true {
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if Task.isCancelled { return }
                    guard let self, self.player.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.playbackFailed = false
                        self.nowPlayingDetail = catchUp == nil ? "Live" : "Catch-up • \(self.catchUpRange)"
                        self.writeGuideDiagnostics("playback ready: \(channel.name) (attempt \(attempt))")
                        self.noteWatchedIfNeeded(channel)
                        // Back out of the poll loop. Without this the ready state is re-logged on
                        // every tick — dozens of identical lines a second, burying everything else.
                        return
                    case .failed:
                        let why = item.error?.localizedDescription ?? "the provider refused the stream"
                        self.writeGuideDiagnostics("playback failed: \(channel.name) attempt \(attempt) as \(format): \(why)")
                        self.formatRefusals[format] = why
                        let tries = (self.formatAttempts[format] ?? 0) + 1
                        self.formatAttempts[format] = tries
                        self.nextProbeAt = start   // the replacement item deserves its own early check
                        if tries < Self.attemptsPerFormat {
                            // The item is dead and cannot recover, so build a new one for the same
                            // container: an edge that refused a moment ago may serve now.
                            self.nowPlayingDetail = "Retrying… (\(tries)/\(Self.attemptsPerFormat))"
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if Task.isCancelled { return }
                            self.startItem(url: url, channel: channel, catchUp: catchUp,
                                           format: format, attempt: tries + 1)
                            return
                        }
                        if self.advanceFormat(channel: channel, catchUp: catchUp, from: format) { return }
                        self.reportUnplayable(channel, detail: why)
                        return
                    default:
                        // Still .unknown, which is the state that used to mean nothing at all. A few
                        // seconds in, ask the provider directly: the answer separates a slow start,
                        // which must keep waiting, from a channel that is dead, which must not.
                        if Date().timeIntervalSince(start) > 4, Date() >= nextProbeAt {
                            let verdict = await self.probeStream(url)
                            if Task.isCancelled { return }
                            // A refusal may have started a new item; this one is no longer ours to
                            // report on.
                            if self.player.currentItem !== item { return }
                            switch verdict {
                            case .refused(let why):
                                self.formatRefusals[format] = why
                                let tries = (self.formatAttempts[format] ?? 0) + 1
                                self.formatAttempts[format] = tries
                                if tries < Self.attemptsPerFormat {
                                    // The player is still working on it, so leave the item alone and
                                    // ask again in a moment.
                                    self.nextProbeAt = Date().addingTimeInterval(2.5)
                                    self.nowPlayingDetail = "Connecting…"
                                    self.writeGuideDiagnostics("playback: \(channel.name) as \(format) refused \(tries)/\(Self.attemptsPerFormat) — \(why); the player is still trying")
                                } else {
                                    self.writeGuideDiagnostics("playback refused: \(channel.name) as \(format) — \(why) (\(tries) times)")
                                    if self.advanceFormat(channel: channel, catchUp: catchUp, from: format) { return }
                                    self.reportUnplayable(channel, detail: why)
                                    return
                                }
                            case .playable:
                                self.nextProbeAt = Date().addingTimeInterval(6)
                                self.writeGuideDiagnostics("playback: \(channel.name) as \(format) is reachable, just slow — still connecting")
                            case .inconclusive(let why):
                                self.nextProbeAt = Date().addingTimeInterval(6)
                                self.writeGuideDiagnostics("playback: \(channel.name) as \(format) probe inconclusive — \(why)")
                            }
                        }
                        continue
                    }
                }
                guard let self, self.player.currentItem === item else { return }
                // Re-read before declaring anything: the status can flip between the last poll and
                // this line, and a timeout message that contradicts itself helps nobody.
                if item.status == .readyToPlay {
                    playbackFailed = false
                    nowPlayingDetail = catchUp == nil ? "Live" : "Catch-up • \(catchUpRange)"
                    writeGuideDiagnostics("playback ready: \(channel.name) (slow start, attempt \(attempt))")
                    noteWatchedIfNeeded(channel)
                    return
                }
                // The window expired with the item still saying nothing. Ask the provider once
                // more and let the answer decide the next move, rather than logging it and giving
                // up: a probe that says "still here, just slow" used to end the task right here,
                // which left nowPlayingDetail frozen at "Still connecting…" forever — nothing was
                // watching the item any more, so even a late readyToPlay went unreported.
                nowPlayingDetail = "Still connecting…"
                let elapsed = Int(Date().timeIntervalSince(start).rounded())
                var report = "itemStatus=\(item.status.rawValue) rate=\(player.rate)"
                let verdict = await probeStream(url)
                // This probe can take a few seconds; by the time it resolves the user may have
                // zapped to a different channel, so writing any of the branches below (a retry, a
                // banner, even a brand-new startItem for this same url) would clobber whatever is
                // actually on screen now. Mirrors the identity guard already used right after the
                // probe in the inner "still .unknown" branch above.
                if Task.isCancelled || self.player.currentItem !== item { return }
                switch verdict {
                case .playable:
                    report += " | provider is serving it (reachable, just slow), still waiting "
                        + "(\(stallExtensions + 1)/\(maxStallExtensions))"
                    writeGuideDiagnostics("playback: \(channel.name) still not playing after \(elapsed)s — \(report)")
                    stallExtensions += 1
                    if stallExtensions >= maxStallExtensions {
                        reportUnplayable(channel, detail: "the provider never finished connecting "
                            + "(it kept answering, but the player never started)")
                        return
                    }
                    deadline = Date().addingTimeInterval(20)
                    nextProbeAt = Date().addingTimeInterval(6)
                    continue
                case .inconclusive(let why):
                    report += " | probe inconclusive: \(why), still waiting "
                        + "(\(stallExtensions + 1)/\(maxStallExtensions))"
                    writeGuideDiagnostics("playback: \(channel.name) still not playing after \(elapsed)s — \(report)")
                    stallExtensions += 1
                    if stallExtensions >= maxStallExtensions {
                        reportUnplayable(channel, detail: "the provider never finished connecting "
                            + "(it kept answering, but the player never started)")
                        return
                    }
                    deadline = Date().addingTimeInterval(20)
                    nextProbeAt = Date().addingTimeInterval(6)
                    continue
                case .refused(let why):
                    report += " | provider refused: \(why)"
                    writeGuideDiagnostics("playback: \(channel.name) still not playing after \(elapsed)s — \(report)")
                    formatRefusals[format] = why
                    let tries = (formatAttempts[format] ?? 0) + 1
                    formatAttempts[format] = tries
                    if tries < Self.attemptsPerFormat {
                        nextProbeAt = .distantPast
                        startItem(url: url, channel: channel, catchUp: catchUp,
                                  format: format, attempt: tries + 1)
                        return
                    }
                    if advanceFormat(channel: channel, catchUp: catchUp, from: format) { return }
                    reportUnplayable(channel, detail: why)
                    return
                }
            }
        }
    }

    /// Re-open the same request after the provider refused it.
    /// Re-open the same request after the provider refused it. The format ladder is reset, so a
    /// transient outage is retried from the preferred container rather than from whichever one
    /// happened to be tried last.
    public func retryPlayback() {
        guard let request = lastPlaybackRequest, let client else { return }
        playbackFailed = false
        nowPlayingDetail = "Connecting…"
        formatRefusals = [:]
        formatAttempts = [:]
        nextProbeAt = .distantPast
        let format = Self.formatCandidates(preferred: settings.data.preferredFormat)[0]
        let catchUpURL = request.catchUp.flatMap { range in
            client.catchUpURL(streamID: request.channel.streamID, start: range.0,
                              durationMinutes: max(1, Int(range.1.timeIntervalSince(range.0) / 60)),
                              format: format)
        }
        let url = catchUpURL ?? client.liveURL(streamID: request.channel.streamID, format: format)
        guard let url else { return }
        triedFormats = [format]
        lastPlaybackRequest = (url, request.channel, request.catchUp)
        startItem(url: url, channel: request.channel, catchUp: request.catchUp,
                  format: format, attempt: 1)
    }

    /// Asks the provider whether the archive actually serves, rather than trusting the
    /// channel flag. The flag can be wrong in both directions: panels exist that carry
    /// catch-up without advertising it, and ones that advertise it and return 404.
    /// Sends a small Range so a working archive does not start streaming a whole file.
    public func probeCatchUp() async -> String {
        guard let client else { return "Not signed in." }
        guard let channel = channels.first(where: { $0.hasArchive }) else {
            return "Nothing to test: no channel advertises an archive. That is the provider's "
                + "setting, not the app's."
        }
        let finished = (guideProgrammes[channel.streamID] ?? []).filter { $0.stop < Date() }
        guard let programme = finished.max(by: { $0.start < $1.start }) else {
            return "\(catchUpChannelCount) channel(s) advertise catch-up, but the guide has no "
                + "finished programme to test with."
        }
        let minutes = max(1, Int(programme.stop.timeIntervalSince(programme.start) / 60))
        guard let url = client.catchUpURL(streamID: channel.streamID,
                                          start: programme.start,
                                          durationMinutes: minutes) else {
            return "Could not build a timeshift URL."
        }
        var request = URLRequest(url: url)
        request.setValue("IPTVMac/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let playlist = String(decoding: data.prefix(16), as: UTF8.self).hasPrefix("#EXTM3U")
            return "\(channel.name) / \(GuideFormat.range(programme.start, programme.stop)): "
                + "HTTP \(status)" + (playlist ? " — playlist received, catch-up works." : "")
        } catch {
            return "\(channel.name): \(error.localizedDescription)"
        }
    }

    public func stopPlayback() {
        // Stop has to mean stop everywhere. Clearing only the title and detail left stale state
        // behind: the guide and the channel list still highlighted the channel, the speaker glyph
        // stayed, the pane kept offering Retry and VLC for it, Playback > Stop stayed enabled — and
        // because the list starts playback on a *change* of selection, a second click on that row
        // became a permanent dead click.
        selectedChannel = nil
        lastPlaybackRequest = nil
        lastMediaRequest = nil
        nowPlayingIsMedia = false
        nowPlayingTask?.cancel()
        mediaStatusTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        nowPlayingTitle = ""
        nowPlayingDetail = ""
        isCatchUp = false
        catchUpRange = ""
    }

    /// Prefers the guide we already downloaded, and only falls back to the short
    /// EPG endpoint for a channel the guide did not cover.
    private func describeNowPlaying(for channel: Channel) async {
        while !Task.isCancelled {
            if let live = currentProgramme(for: channel) {
                nowPlayingDetail = "\(GuideFormat.range(live.start, live.stop))  \(live.title)"
            } else if let client,
                      let programmes = try? await client.shortEPG(streamID: channel.streamID, limit: 3),
                      !programmes.isEmpty {
                let live = programmes.first { $0.isLive } ?? programmes[0]
                nowPlayingDetail = "\(live.timeRangeText)  \(live.title)"
            } else {
                nowPlayingDetail = "No programme data from this provider"
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    /// Hand the raw transport stream to an external player for the formats
    /// AVPlayer cannot open. Same credentials, same provider — this does not
    /// bypass anything, it is the documented fallback.
    public func externalURL(for channel: Channel) -> URL? {
        client?.liveURL(streamID: channel.streamID, format: "ts")
    }

    public func openInVLC(_ channel: Channel) {
        guard let url = externalURL(for: channel) else { return }
        openExternalPlayer(url: url)
    }

    /// Shared by live/catch-up (which rebuild their URL from the channel) and VOD/episodes
    /// (which already have the one direct URL and have nothing to rebuild).
    private func openExternalPlayer(url: URL) {
        let appURL = URL(fileURLWithPath: settings.data.openInVLCPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            banner = "No app at \(settings.data.openInVLCPath) — set the path in Settings › Playback."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error { Task { @MainActor in self.banner = "VLC could not open the stream: \(error.localizedDescription)" } }
        }
    }

    // MARK: - Guide timeline

    /// How far the guide's timeline sits from now. Moving it walks the grid onto earlier or
    /// later programmes, which is the only way to reach catch-up on a provider that sells it.
    @Published public var guideJumpMinutes: Int = 0

    /// Steps the guide window, bounded to a day either way. Past the ends of the guide data
    /// every row is empty, which reads as broken rather than as "look somewhere else".
    public func jumpGuide(byMinutes minutes: Int) {
        guideJumpMinutes = max(-24 * 60, min(24 * 60, guideJumpMinutes + minutes))
    }

    public func jumpGuideToNow() { guideJumpMinutes = 0 }

    // MARK: - Diagnostics

    public func runDiagnostics() {
        guard let client, let account else { diagnosticsResult = "Not signed in."; return }
        diagnosticsResult = "checking…"
        Task {
            var lines = [
                "server        \(portalHost)",
                "status        \(account.userInfo.status)",
                "expires       \(account.userInfo.expiryText)",
                "connections   \(connectionText)",
                "formats       \(account.userInfo.allowedOutputFormats.joined(separator: ", "))",
                "catalog       \(catalogStats)",
                "guide         \(guideStatus)",
                "streams       \(channels.count) usable",
            ]
            if let probe = channels.first(where: { $0.streamID != 0 }),
               let url = client.liveURL(streamID: probe.streamID) {
                let started = Date()
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse {
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    lines.append("playback      HTTP \(http.statusCode) in \(ms) ms (\(probe.name))")
                } else {
                    lines.append("playback      no response from the provider")
                }
            }
            diagnosticsResult = lines.joined(separator: "\n")
        }
    }
}
