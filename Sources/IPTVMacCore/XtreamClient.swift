import Foundation

public enum XtreamError: LocalizedError {
    case badServer(String)
    case http(Int, String)
    case notXtream(String)
    case authRejected(status: String, message: String)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .badServer(let s):
            return "“\(s)” isn’t a usable server address."
        case .http(let code, let detail):
            let d = detail.isEmpty ? "" : " — \(detail)"
            return "The server answered HTTP \(code).\(d)"
        case .notXtream(let host):
            return "\(host) answered, but not like an Xtream Codes portal. Check the address and port."
        case .authRejected(let status, let message):
            let s = status.isEmpty ? "unknown" : status
            let m = message.isEmpty ? "" : " (\(message))"
            return "The provider rejected that username and password — status \(s).\(m)"
        case .decoding(let detail):
            return "Couldn’t read the provider’s response: \(detail)"
        case .transport(let detail):
            return "Network problem: \(detail)"
        }
    }
}

/// Thin, dependency-free Xtream Codes client.
public final class XtreamClient: @unchecked Sendable {
    public let credentials: Credentials
    public let base: String
    private let session: URLSession

    public init(credentials: Credentials, timeout: TimeInterval = 30) {
        self.credentials = credentials
        self.base = XtreamClient.normalizeServer(credentials.server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": XtreamClient.userAgent]
        self.session = URLSession(configuration: configuration)
    }

    public static let userAgent = "IPTVMac/1.0"

    // MARK: - URL normalisation

    /// Accepts what a human actually types: `host:port`, `http://host:port/`,
    /// `http://host/player_api.php`, and strips it down to a base we can append to.
    public static func normalizeServer(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        func stripTrailingSlashes() { while s.hasSuffix("/") { s.removeLast() } }
        stripTrailingSlashes()
        for suffix in ["/player_api.php", "/get.php", "/xmltv.php", "/c"] {
            if s.lowercased().hasSuffix(suffix) {
                s.removeLast(suffix.count)
                stripTrailingSlashes()
            }
        }
        return s
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// `{base}/player_api.php?username=…&password=…[&action=…]`
    private func apiURL(_ extra: [(String, String)] = []) -> URL? {
        var items = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
        ]
        items.append(contentsOf: extra.map { URLQueryItem(name: $0.0, value: $0.1) })
        var components = URLComponents(string: base + "/player_api.php")
        components?.queryItems = items
        return components?.url
    }

    private func pathURL(_ path: String) -> URL? {
        URL(string: base + path)
    }

    // MARK: - Transport

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(XtreamClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let snippet = String(data: data.prefix(200), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw XtreamError.http(http.statusCode, snippet)
            }
            return data
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let head = String(data: data.prefix(64), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           head.hasPrefix("<") {
            throw XtreamError.notXtream(base)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw XtreamError.decoding(String(describing: error))
        }
    }

    // MARK: - API

    public func login() async throws -> Account {
        guard let url = apiURL() else { throw XtreamError.badServer(base) }
        let account: Account = try decode(Account.self, from: try await fetch(url))
        guard account.userInfo.auth == 1 else {
            throw XtreamError.authRejected(status: account.userInfo.status,
                                           message: account.userInfo.message)
        }
        return account
    }

    public func liveCategories() async throws -> [ChannelCategory] {
        guard let url = apiURL([("action", "get_live_categories")]) else {
            throw XtreamError.badServer(base)
        }
        return try decode([ChannelCategory].self, from: try await fetch(url))
    }

    public func liveStreams(categoryID: String? = nil) async throws -> [Channel] {
        var extra = [("action", "get_live_streams")]
        if let categoryID, !categoryID.isEmpty {
            extra.append(("category_id", categoryID))
        }
        guard let url = apiURL(extra) else { throw XtreamError.badServer(base) }
        return try decode([Channel].self, from: try await fetch(url))
    }

    private struct EPGEnvelope: Decodable { let epg_listings: [Programme]? }

    public func shortEPG(streamID: Int, limit: Int = 4) async throws -> [Programme] {
        guard let url = apiURL([
            ("action", "get_short_epg"),
            ("stream_id", String(streamID)),
            ("limit", String(limit)),
        ]) else { throw XtreamError.badServer(base) }
        let data = try await fetch(url)
        if let envelope = try? JSONDecoder().decode(EPGEnvelope.self, from: data),
           let listings = envelope.epg_listings {
            return listings
        }
        if let listings = try? JSONDecoder().decode([Programme].self, from: data) {
            return listings
        }
        return []
    }

    /// Downloads the guide straight to `destination` and returns its size in bytes.
    /// A guide can be a hundred megabytes; URLSession's own download task streams it
    /// to a temporary file, so it is never held whole in memory, and the result is
    /// moved into place atomically enough for our purposes.
    public func downloadXMLTVFile(to destination: URL, timeout: TimeInterval = 300) async throws -> Int {
        guard let source = xmltvURL() else { throw XtreamError.badServer(base) }
        var request = URLRequest(url: source)
        request.setValue(XtreamClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw XtreamError.http(http.statusCode, "guide download")
            }
            let manager = FileManager.default
            let folder = destination.deletingLastPathComponent()
            if !manager.fileExists(atPath: folder.path) {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
            let attributes = try? manager.attributesOfItem(atPath: destination.path)
            return (attributes?[.size] as? Int) ?? 0
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.transport(error.localizedDescription)
        }
    }

    /// The full guide. Tens of megabytes and slow, so it gets its own timeout
    /// rather than the 30 s the API calls use.
    public func xmltvData(timeout: TimeInterval = 180) async throws -> Data {
        guard let url = xmltvURL() else { throw XtreamError.badServer(base) }
        var request = URLRequest(url: url)
        request.setValue(XtreamClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw XtreamError.http(http.statusCode, "guide download")
            }
            return data
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.transport(error.localizedDescription)
        }
    }

    public func vodCategories() async throws -> [ChannelCategory] {
        guard let url = apiURL([("action", "get_vod_categories")]) else {
            throw XtreamError.badServer(base)
        }
        return try decode([ChannelCategory].self, from: try await fetch(url))
    }

    public func vodStreams(categoryID: String? = nil) async throws -> [VODStream] {
        var extra = [("action", "get_vod_streams")]
        if let categoryID, !categoryID.isEmpty {
            extra.append(("category_id", categoryID))
        }
        guard let url = apiURL(extra) else { throw XtreamError.badServer(base) }
        return try decode([VODStream].self, from: try await fetch(url))
    }

    public func seriesCategories() async throws -> [ChannelCategory] {
        guard let url = apiURL([("action", "get_series_categories")]) else {
            throw XtreamError.badServer(base)
        }
        return try decode([ChannelCategory].self, from: try await fetch(url))
    }

    public func seriesList(categoryID: String? = nil) async throws -> [SeriesSummary] {
        var extra = [("action", "get_series")]
        if let categoryID, !categoryID.isEmpty {
            extra.append(("category_id", categoryID))
        }
        guard let url = apiURL(extra) else { throw XtreamError.badServer(base) }
        return try decode([SeriesSummary].self, from: try await fetch(url))
    }

    /// `get_series_info` nests episodes under a season-number string key
    /// (`{"episodes": {"1": [...], "2": [...]}}`). Grouped by season here so callers never see
    /// the provider's string-keyed shape, and sorted within each season by episode number.
    public func seriesEpisodes(seriesID: Int) async throws -> [Int: [SeriesEpisode]] {
        guard let url = apiURL([("action", "get_series_info"), ("series_id", String(seriesID))])
        else { throw XtreamError.badServer(base) }
        struct Envelope: Decodable { let episodes: [String: [SeriesEpisode]]? }
        let envelope = try decode(Envelope.self, from: try await fetch(url))
        var bySeason: [Int: [SeriesEpisode]] = [:]
        for (key, value) in envelope.episodes ?? [:] {
            bySeason[Int(key) ?? 0, default: []].append(contentsOf: value)
        }
        for key in bySeason.keys {
            bySeason[key]?.sort { $0.episodeNumber < $1.episodeNumber }
        }
        return bySeason
    }

    // MARK: - Stream URLs

    public func liveURL(streamID: Int, format: String = "m3u8") -> URL? {
        pathURL("/live/\(XtreamClient.escape(credentials.username))/"
                + "\(XtreamClient.escape(credentials.password))/\(streamID).\(format)")
    }

    /// `{base}/movie/U/P/{vod_id}.{ext}` — `ext` is the stream's own `container_extension`,
    /// not a format the app chooses, so there is no format ladder to climb here the way live
    /// and catch-up have one.
    public func vodURL(streamID: Int, ext: String) -> URL? {
        let container = ext.isEmpty ? "mp4" : ext
        return pathURL("/movie/\(XtreamClient.escape(credentials.username))/"
                       + "\(XtreamClient.escape(credentials.password))/\(streamID).\(container)")
    }

    /// `{base}/series/U/P/{episode_id}.{ext}`
    public func episodeURL(episodeID: Int, ext: String) -> URL? {
        let container = ext.isEmpty ? "mp4" : ext
        return pathURL("/series/\(XtreamClient.escape(credentials.username))/"
                       + "\(XtreamClient.escape(credentials.password))/\(episodeID).\(container)")
    }

    /// The panel's own timezone, once the account info has been read. The archive timestamp below
    /// is interpreted by the panel in ITS timezone, not in UTC and not in the viewer's.
    public var panelTimeZone: TimeZone?

    /// `{base}/timeshift/U/P/{minutes}/{yyyy-MM-dd:HH-mm}/{stream_id}.{ext}`
    ///
    /// The start stamp is SERVER-LOCAL. The panel parses it with its own default timezone and names
    /// its archive files the same way, so sending UTC asks for a window that is however many hours
    /// off — a mistake this comment previously asserted was universal while committing it itself.
    /// Public documentation and three independent client implementations agree on server-local;
    /// `AppModel.connect()` sets `panelTimeZone` from the account's `server_info.timezone` as
    /// soon as login succeeds, falling back to the viewer's own zone when the panel didn't
    /// report one (or reported something `TimeZone` doesn't recognise).
    public func catchUpURL(streamID: Int,
                           start: Date,
                           durationMinutes: Int,
                           format: String = "m3u8") -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = panelTimeZone ?? .current
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        let stamp = formatter.string(from: start)
        return pathURL("/timeshift/\(XtreamClient.escape(credentials.username))/"
                       + "\(XtreamClient.escape(credentials.password))/"
                       + "\(durationMinutes)/\(stamp)/\(streamID).\(format)")
    }

    public func xmltvURL() -> URL? {
        guard let base = URL(string: base) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("xmltv.php"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
        ]
        return components?.url
    }
}
