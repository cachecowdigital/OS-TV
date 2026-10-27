import Foundation

// MARK: - Identity
//
// `stream_id` is unique only within one portal, and so is `category_id`. Every collection that
// keyed on a bare Int or String therefore collides the moment a second provider exists: the same
// channel id 647 appears on both of this owner's subscriptions, in favourites, in the guide cache
// and on disk. These types namespace every identity that crosses a provider boundary.

public struct PlaylistID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init() { rawValue = UUID().uuidString }
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let unassigned = PlaylistID(rawValue: "_unassigned_")
    public var description: String { rawValue }
    /// Each playlist gets its own Keychain account so secrets never share one item.
    public var keychainAccount: String { "playlist-" + rawValue }
}

public struct ProfileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init() { rawValue = UUID().uuidString }
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let standard = ProfileID(rawValue: "default")
    public var description: String { rawValue }
}

public struct ChannelKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let playlist: PlaylistID
    public let streamID: Int
    public init(playlist: PlaylistID, streamID: Int) {
        self.playlist = playlist
        self.streamID = streamID
    }
    public var description: String { playlist.rawValue + ":" + String(streamID) }
}

public struct CategoryKey: Hashable, Codable, Sendable {
    public let playlist: PlaylistID
    public let categoryID: String
    public init(playlist: PlaylistID, categoryID: String) {
        self.playlist = playlist
        self.categoryID = categoryID
    }
}

// MARK: - Playlists

/// How a playlist is reached. Credentials are never part of this value: an M3U URL can carry the
/// subscription in its own query string, so what is stored here is a credential-free rendering
/// and the real URL lives in the Keychain.
public enum PlaylistKind: Codable, Hashable, Sendable {
    /// Host only. The username is half of a credential pair, so it lives in the Keychain with the
    /// password rather than on disk in the index.
    case xtream(host: String)
    case m3uRemote(displayURL: String)
    case m3uLocal(bookmark: Data, displayName: String)

    public var badge: String {
        switch self {
        case .xtream: return "Xtream"
        case .m3uRemote: return "M3U URL"
        case .m3uLocal: return "M3U file"
        }
    }

    /// What may be shown in the UI. Never the username, never a full M3U URL.
    public var displayTarget: String {
        switch self {
        case .xtream(let host): return host
        case .m3uRemote(let displayURL): return displayURL
        case .m3uLocal(_, let displayName): return displayName
        }
    }

    public var isRemote: Bool {
        if case .m3uLocal = self { return false }
        return true
    }
}

/// A guide source for a playlist. XMLTV sources are shared between playlists by id, matching how
/// TiviMate installs EPG sources system-wide rather than per playlist.
public enum EPGSource: Codable, Hashable, Sendable {
    case embedded
    case xmltv(id: String, displayURL: String)
    case none

    public var displayTarget: String {
        switch self {
        case .embedded: return "Provider guide"
        case .xmltv(_, let displayURL): return displayURL
        case .none: return "None"
        }
    }
}

public struct EPGSourceRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var displayURL: String
    public var refreshMinutes: Int
    public var lastRefresh: Date?

    public init(id: String, name: String, displayURL: String,
                refreshMinutes: Int = 60, lastRefresh: Date? = nil) {
        self.id = id
        self.name = name
        self.displayURL = displayURL
        self.refreshMinutes = refreshMinutes
        self.lastRefresh = lastRefresh
    }
}

public struct Playlist: Identifiable, Codable, Hashable, Sendable {
    public var id: PlaylistID
    public var name: String
    public var kind: PlaylistKind
    /// The hide-without-deleting switch. A disabled playlist keeps its settings and its entries
    /// simply stop appearing.
    public var isEnabled: Bool
    /// Display order only. Never identity: reordering must not lose favourites.
    public var order: Int
    public var epg: EPGSource
    /// Manual correction, seeded from an M3U `tvg-shift` (hours) or the panel's server timezone.
    public var epgShiftMinutes: Int
    /// Last measured correction from GuideAlignment. Empirical beats declared, so this is what is
    /// used unless the user has set the manual value.
    public var epgDetectedShiftMinutes: Int
    public var userAgentOverride: String?
    public var lastCatalogRefresh: Date?
    /// The v1 cache filename, kept so an upgrade can reuse a guide it already downloaded.
    public var legacyGuideCacheKey: String?

    public init(id: PlaylistID, name: String, kind: PlaylistKind,
                isEnabled: Bool = true, order: Int = 0, epg: EPGSource = .embedded,
                epgShiftMinutes: Int = 0, epgDetectedShiftMinutes: Int = 0,
                userAgentOverride: String? = nil, lastCatalogRefresh: Date? = nil,
                legacyGuideCacheKey: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.order = order
        self.epg = epg
        self.epgShiftMinutes = epgShiftMinutes
        self.epgDetectedShiftMinutes = epgDetectedShiftMinutes
        self.userAgentOverride = userAgentOverride
        self.lastCatalogRefresh = lastCatalogRefresh
        self.legacyGuideCacheKey = legacyGuideCacheKey
    }

    public var effectiveShiftMinutes: Int {
        epgShiftMinutes != 0 ? epgShiftMinutes : epgDetectedShiftMinutes
    }
}

// MARK: - Profiles

public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public var id: ProfileID
    public var name: String
    public var symbol: String
    /// Salted hash only. The PIN itself is never stored.
    public var pinSalt: Data?
    public var pinHash: Data?
    /// Empty means "everything enabled". A non-empty list narrows visibility; it must never
    /// resurrect a playlist the owner switched off.
    public var visiblePlaylistIDs: [PlaylistID]

    public init(id: ProfileID = ProfileID(), name: String, symbol: String = "person.crop.circle",
                pinSalt: Data? = nil, pinHash: Data? = nil,
                visiblePlaylistIDs: [PlaylistID] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.pinSalt = pinSalt
        self.pinHash = pinHash
        self.visiblePlaylistIDs = visiblePlaylistIDs
    }
}

// MARK: - The index

public struct LibraryIndex: Codable, Sendable {
    public var schemaVersion: Int
    public var playlists: [Playlist]
    public var epgSources: [EPGSourceRecord]
    public var profiles: [Profile]
    public var activeProfileID: ProfileID?
    /// Which ONE playlist is the live, signed-in connection right now. Distinct from
    /// `activeProfileID` (who's watching) and from `enabledPlaylists` (the bigger
    /// simultaneous-multi-provider-merge design this app doesn't do yet): this app connects to
    /// one provider at a time and switches, so this is simply "which saved subscription is it."
    public var activePlaylistID: PlaylistID?

    public init(schemaVersion: Int = 2, playlists: [Playlist] = [],
                epgSources: [EPGSourceRecord] = [], profiles: [Profile] = [],
                activeProfileID: ProfileID? = nil, activePlaylistID: PlaylistID? = nil) {
        self.schemaVersion = schemaVersion
        self.playlists = playlists
        self.epgSources = epgSources
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.activePlaylistID = activePlaylistID
    }

    // MARK: Derived policy

    public var orderedPlaylists: [Playlist] {
        playlists.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// Enabled *and* visible to the active profile. A disabled playlist is never returned, however
    /// the profile is configured.
    public var enabledPlaylists: [Playlist] {
        let visible = Set(activeProfile?.visiblePlaylistIDs ?? [])
        return orderedPlaylists.filter { playlist in
            guard playlist.isEnabled else { return false }
            if visible.isEmpty { return true }
            return visible.contains(playlist.id)
        }
    }

    public var activeProfile: Profile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    public func playlist(_ id: PlaylistID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    public mutating func setEnabled(_ id: PlaylistID, _ enabled: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].isEnabled = enabled
    }

    /// Moves a playlist within the display order. Swaps with its neighbour so orders stay dense.
    @discardableResult
    public mutating func move(_ id: PlaylistID, by offset: Int) -> Bool {
        var sorted = orderedPlaylists
        guard let from = sorted.firstIndex(where: { $0.id == id }) else { return false }
        let to = from + offset
        guard sorted.indices.contains(to) else { return false }
        sorted.swapAt(from, to)
        for (position, playlist) in sorted.enumerated() {
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index].order = position
            }
        }
        return true
    }

    public mutating func add(_ playlist: Playlist) {
        var fresh = playlist
        fresh.order = (playlists.map(\.order).max() ?? -1) + 1
        playlists.append(fresh)
    }

    /// Removing a playlist is the destructive path; switching one off is `setEnabled`.
    public mutating func remove(_ id: PlaylistID) {
        playlists.removeAll { $0.id == id }
        for index in profiles.indices {
            profiles[index].visiblePlaylistIDs.removeAll { $0 == id }
        }
    }
}

// MARK: - Secrets (Keychain only, never in the index)

public struct PlaylistSecret: Codable, Hashable, Sendable {
    /// Xtream authenticates on this pair, and either half is enough to hurt. Both stay here.
    public var username: String?
    public var password: String?
    /// For an M3U URL the whole URL is the secret: it can carry the subscription in its query.
    public var fullURL: String?
    public init(username: String? = nil, password: String? = nil, fullURL: String? = nil) {
        self.username = username
        self.password = password
        self.fullURL = fullURL
    }
}

public struct EPGSecret: Codable, Hashable, Sendable {
    public var fullURL: String
    public init(fullURL: String) { self.fullURL = fullURL }
}

// MARK: - Provider abstraction

public struct Catalog: Sendable {
    public var categories: [ChannelCategory]
    public var channels: [Channel]
    public init(categories: [ChannelCategory] = [], channels: [Channel] = []) {
        self.categories = categories
        self.channels = channels
    }
}

/// Xtream and M3U are two front doors to the same shape. Everything above the protocol works on
/// `Channel` and never asks which kind of provider produced it.
public protocol ChannelProvider: Sendable {
    var id: PlaylistID { get }
    var name: String { get }
    func loadCatalog() async throws -> Catalog
    func liveURL(for channel: Channel, format: String) -> URL?
    func catchUpURL(for channel: Channel, start: Date, durationMinutes: Int, format: String) -> URL?
    /// Nil when the playlist carries no guide of its own.
    func embeddedGuideURL() -> URL?
}

public extension ChannelProvider {
    func catchUpURL(for channel: Channel, start: Date, durationMinutes: Int, format: String) -> URL? { nil }
    func embeddedGuideURL() -> URL? { nil }
}

// MARK: - Persistence

/// Where the library lives. Small, credential-free, and separate from the per-profile settings and
/// favourites blobs, which stay keyed by profile id.
/// UserDefaults is not Sendable, and wrapping it in a claim that it is would be a lie the Swift 6
/// language mode would turn into an error. The store is a thin, synchronous wrapper; callers keep
/// it on one actor.
public struct LibraryStore {
    public static let defaultsKey = "jabcorptv.library.v2"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = LibraryStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> LibraryIndex {
        guard let data = defaults.data(forKey: key),
              let index = try? JSONDecoder().decode(LibraryIndex.self, from: data)
        else { return LibraryIndex() }
        return index
    }

    public func save(_ index: LibraryIndex) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        defaults.set(data, forKey: key)
    }
}
