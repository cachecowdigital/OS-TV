import Foundation

// MARK: - Account

public struct Account: Decodable, Sendable {
    public let userInfo: UserInfo
    public let serverInfo: ServerInfo

    enum K: String, CodingKey { case user_info, server_info }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        userInfo = (try? c.decode(UserInfo.self, forKey: .user_info)) ?? .empty
        serverInfo = (try? c.decode(ServerInfo.self, forKey: .server_info)) ?? .empty
    }

    public init(userInfo: UserInfo, serverInfo: ServerInfo) {
        self.userInfo = userInfo
        self.serverInfo = serverInfo
    }
}

public struct UserInfo: Decodable, Sendable {
    public let username: String
    public let message: String
    public let auth: Int
    public let status: String
    public let expDate: Date?
    public let isTrial: Bool
    public let activeConnections: Int
    public let maxConnections: Int
    public let allowedOutputFormats: [String]

    enum K: String, CodingKey {
        case username, message, auth, status, exp_date, is_trial,
             active_cons, max_connections, allowed_output_formats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        username = c.str(.username) ?? ""
        message = c.str(.message) ?? ""
        auth = c.int(.auth) ?? 0
        status = c.str(.status) ?? ""
        isTrial = (c.int(.is_trial) ?? 0) == 1
        activeConnections = c.int(.active_cons) ?? 0
        maxConnections = c.int(.max_connections) ?? 0
        allowedOutputFormats = c.strArray(.allowed_output_formats)
        if let t = c.int(.exp_date), t > 0 {
            expDate = Date(timeIntervalSince1970: TimeInterval(t))
        } else {
            expDate = nil
        }
    }

    public static let empty = UserInfo()

    private init() {
        username = ""; message = ""; auth = 0; status = ""
        expDate = nil; isTrial = false
        activeConnections = 0; maxConnections = 0
        allowedOutputFormats = []
    }

    public var expiryText: String {
        guard let e = expDate else { return "no expiry reported" }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: e)
    }
}

public struct ServerInfo: Decodable, Sendable {
    public let host: String
    public let port: String
    public let serverProtocol: String
    public let timezone: String
    public let version: String
    public let isXtreamUI: Bool

    enum K: String, CodingKey {
        case url, port, https_port, server_protocol, timezone, xui, version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        host = c.str(.url) ?? ""
        port = c.str(.port) ?? ""
        serverProtocol = c.str(.server_protocol) ?? ""
        timezone = c.str(.timezone) ?? ""
        version = c.str(.version) ?? ""
        isXtreamUI = (c.int(.xui) ?? 0) == 1
    }

    public static let empty = ServerInfo()

    private init() {
        host = ""; port = ""; serverProtocol = ""; timezone = ""; version = ""; isXtreamUI = false
    }
}

// MARK: - Categories

/// Deliberately not named `Category`: that identifier collides with the ObjC
/// runtime's `Category` struct as soon as AppKit or AVKit is imported.
public struct ChannelCategory: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let parentID: Int
    /// As on Channel: category ids are unique only within one portal.
    public let playlist: PlaylistID

    public var key: CategoryKey { CategoryKey(playlist: playlist, categoryID: id) }

    enum K: String, CodingKey { case category_id, category_name, parent_id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.str(.category_id) ?? ""
        name = c.str(.category_name) ?? ""
        parentID = c.int(.parent_id) ?? 0
        playlist = .unassigned
    }

    public init(id: String, name: String, parentID: Int = 0,
                playlist: PlaylistID = .unassigned) {
        self.id = id; self.name = name; self.parentID = parentID; self.playlist = playlist
    }

    public init(from decoder: Decoder, playlist: PlaylistID) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.str(.category_id) ?? ""
        name = c.str(.category_name) ?? ""
        parentID = c.int(.parent_id) ?? 0
        self.playlist = playlist
    }

    public func inPlaylist(_ id: PlaylistID) -> ChannelCategory {
        ChannelCategory(id: self.id, name: name, parentID: parentID, playlist: id)
    }
}

// MARK: - Channels

public struct Channel: Decodable, Sendable, Identifiable, Hashable {
    public let streamID: Int
    public let number: Int
    public let name: String
    public let iconURL: String?
    public let epgChannelID: String?
    public let categoryID: String?
    public let hasArchiveFlag: Bool
    public let archiveDays: Int
    public let directSource: String?
    /// Which playlist this channel came from. `stream_id` is unique only within a portal, so
    /// identity is this plus the id — see ChannelKey. Decoding leaves it unassigned and the loader
    /// stamps the real value, so nothing downstream has to know how the channel was obtained.
    public let playlist: PlaylistID

    enum K: String, CodingKey {
        case num, name, stream_id, stream_icon, epg_channel_id, category_id,
             tv_archive, tv_archive_duration, direct_source
    }

    /// Still the bare stream id, because changing it is the phase-3 change that touches every list
    /// and dictionary in the app. `key` is the collision-free identity already, and is what new
    /// code should use.
    public var id: Int { streamID }
    public var hasArchive: Bool { hasArchiveFlag && archiveDays > 0 }
    public var key: ChannelKey { ChannelKey(playlist: playlist, streamID: streamID) }

    public init(streamID: Int, number: Int, name: String, iconURL: String? = nil,
                epgChannelID: String? = nil, categoryID: String? = nil,
                hasArchiveFlag: Bool = false, archiveDays: Int = 0,
                directSource: String? = nil, playlist: PlaylistID = .unassigned) {
        self.playlist = playlist
        self.streamID = streamID
        self.number = number
        self.name = name
        self.iconURL = iconURL
        self.epgChannelID = epgChannelID
        self.categoryID = categoryID
        self.hasArchiveFlag = hasArchiveFlag
        self.archiveDays = archiveDays
        self.directSource = directSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        streamID = c.int(.stream_id) ?? 0
        number = c.int(.num) ?? 0
        name = c.str(.name) ?? "(unnamed)"
        iconURL = c.str(.stream_icon)
        epgChannelID = c.str(.epg_channel_id)
        categoryID = c.str(.category_id)
        hasArchiveFlag = (c.int(.tv_archive) ?? 0) == 1
        archiveDays = c.int(.tv_archive_duration) ?? 0
        directSource = c.str(.direct_source)
        playlist = .unassigned
    }

    /// The same channel, belonging to a playlist. A copy rather than a mutation so channels can be
    /// shared while merging without one provider's stamp leaking onto another's.
    public func inPlaylist(_ id: PlaylistID) -> Channel {
        Channel(streamID: streamID, number: number, name: name, iconURL: iconURL,
                epgChannelID: epgChannelID, categoryID: categoryID,
                hasArchiveFlag: hasArchiveFlag, archiveDays: archiveDays,
                directSource: directSource, playlist: id)
    }
}

// MARK: - EPG

public struct Programme: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    public let start: Date
    public let end: Date

    enum K: String, CodingKey {
        case id, title, description, start_timestamp, stop_timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.str(.id) ?? UUID().uuidString
        title = Programme.decodeBase64(c.str(.title))
        detail = Programme.decodeBase64(c.str(.description))
        start = Date(timeIntervalSince1970: TimeInterval(c.int(.start_timestamp) ?? 0))
        end = Date(timeIntervalSince1970: TimeInterval(c.int(.stop_timestamp) ?? 0))
    }

    public init(id: String, title: String, detail: String, start: Date, end: Date) {
        self.id = id; self.title = title; self.detail = detail
        self.start = start; self.end = end
    }

    /// Xtream returns programme titles and descriptions base64-encoded. If the
    /// value is not decodable base64 (some panels send plain text) keep it as-is.
    public static func decodeBase64(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return raw }
        return text
    }

    public var isLive: Bool {
        let now = Date()
        return start <= now && now < end
    }

    public var timeRangeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

// MARK: - VOD (movies)

public struct VODStream: Decodable, Sendable, Identifiable, Hashable {
    public let streamID: Int
    public let name: String
    public let iconURL: String?
    public let categoryID: String?
    public let containerExtension: String
    public let rating: String?
    public let plot: String?

    enum K: String, CodingKey {
        case stream_id, name, stream_icon, category_id, container_extension, rating, plot
    }

    public var id: Int { streamID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        streamID = c.int(.stream_id) ?? 0
        name = c.str(.name) ?? "(untitled)"
        iconURL = c.str(.stream_icon)
        categoryID = c.str(.category_id)
        containerExtension = c.str(.container_extension) ?? "mp4"
        rating = c.str(.rating)
        plot = c.str(.plot)
    }
}

// MARK: - Series (TV shows)

public struct SeriesSummary: Decodable, Sendable, Identifiable, Hashable {
    public let seriesID: Int
    public let name: String
    public let iconURL: String?
    public let categoryID: String?
    public let rating: String?
    public let plot: String?

    enum K: String, CodingKey { case series_id, name, cover, category_id, rating, plot }

    public var id: Int { seriesID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        seriesID = c.int(.series_id) ?? 0
        name = c.str(.name) ?? "(untitled)"
        iconURL = c.str(.cover)
        categoryID = c.str(.category_id)
        rating = c.str(.rating)
        plot = c.str(.plot)
    }
}

/// One episode from `get_series_info`. The provider nests these under a season-number
/// string key (`{"episodes": {"1": [...], "2": [...]}}`); `season` is also present on
/// the episode object itself, so decoding needs nothing from the outer key — confirmed
/// against a live provider rather than assumed from the Xtream docs alone.
public struct SeriesEpisode: Decodable, Sendable, Identifiable, Hashable {
    public let episodeID: Int
    public let title: String
    public let containerExtension: String
    public let season: Int
    public let episodeNumber: Int

    enum K: String, CodingKey { case id, title, container_extension, episode_num, season }

    public var id: Int { episodeID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        episodeID = c.int(.id) ?? 0
        title = c.str(.title) ?? "(untitled)"
        containerExtension = c.str(.container_extension) ?? "mp4"
        season = c.int(.season) ?? 0
        episodeNumber = c.int(.episode_num) ?? 0
    }
}
