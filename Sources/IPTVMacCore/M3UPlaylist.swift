import Foundation

// MARK: - M3U playlists
//
// The other front door. Xtream answers with JSON; an M3U provider answers with a text file whose
// conventions are only ever half-standardised, so this parser is deliberately forgiving: a line it
// cannot use is counted and skipped rather than thrown, because a playlist with one broken entry is
// still a playlist.
//
// SECURITY: the stream URLs this produces are credential-bearing. An M3U URL frequently carries the
// subscription in its own query string, and per-channel URLs can carry tokens of their own. Nothing
// here is ever logged or written to disk.

public enum M3U {

    /// The `#EXTM3U` line's attributes. `url-tvg` publishes the guide (often gzipped), and
    /// `tvg-shift` declares the guide's clock offset **in hours**, which is the one conversion this
    /// format does not do for you.
    public struct Header: Hashable, Sendable {
        public var guideURLs: [String]
        public var declaredShiftMinutes: Int
        public var hasTag: Bool

        public init(guideURLs: [String] = [], declaredShiftMinutes: Int = 0, hasTag: Bool = false) {
            self.guideURLs = guideURLs
            self.declaredShiftMinutes = declaredShiftMinutes
            self.hasTag = hasTag
        }
    }

    public struct Parsed: Sendable {
        public var header: Header
        public var categories: [ChannelCategory]
        public var channels: [Channel]
        /// How many `#EXTINF` entries were unusable. Surfaced so a mostly-empty playlist reads as a
        /// parse problem rather than as a provider with no channels.
        public var skippedEntries: Int

        public init(header: Header = Header(), categories: [ChannelCategory] = [],
                    channels: [Channel] = [], skippedEntries: Int = 0) {
            self.header = header
            self.categories = categories
            self.channels = channels
            self.skippedEntries = skippedEntries
        }
    }

    public static let ungroupedName = "Ungrouped"

    // MARK: Parsing

    /// Parses a playlist. `playlist` stamps every channel and category with its origin, which is
    /// what makes two playlists coexist.
    public static func parse(_ text: String, playlist: PlaylistID) -> Parsed {
        var header = Header()
        var categories: [ChannelCategory] = []
        var seenGroups: Set<String> = []
        var channels: [Channel] = []
        var skipped = 0

        // A pending entry waits for its URL line, which is how this format is shaped.
        var pendingAttrs: [String: String] = [:]
        var pendingName: String?
        var pendingGroup: String?
        var sequence = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTM3U") {
                header = parseHeader(line)
                continue
            }

            if line.hasPrefix("#EXTINF:") {
                let entry = parseExtInf(line)
                pendingAttrs = entry.attributes
                pendingName = entry.title
                sequence += 1
                continue
            }

            // A group for the next entry only, or until the next #EXTGRP.
            if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            // Directives that only matter to other players.
            if line.hasPrefix("#") { continue }

            guard let streamURL = URL(string: line), streamURL.scheme != nil else {
                if pendingName != nil { skipped += 1; pendingName = nil }
                continue
            }

            guard let name = pendingName, !name.isEmpty else {
                // A bare URL with no #EXTINF above it: usable, but nameless.
                skipped += 1
                continue
            }

            let group = pendingGroup ?? pendingAttrs["group-title"] ?? M3U.ungroupedName
            let categoryID = slug(group)
            if seenGroups.insert(categoryID).inserted {
                categories.append(ChannelCategory(id: categoryID, name: group,
                                                  parentID: 0, playlist: playlist))
            }

            let catchupDays = Int(pendingAttrs["catchup-days"] ?? "") ?? 0
            let hasCatchup = pendingAttrs["catchup"] != nil || catchupDays > 0

            channels.append(Channel(
                // Identity hashed from the stream URL, so a provider re-ordering or renumbering its
                // file does not orphan a favourite. Parse order is deliberately not an input.
                streamID: stableID(for: line),
                number: Int(pendingAttrs["tvg-chno"] ?? "") ?? sequence,
                name: name,
                iconURL: nonEmpty(pendingAttrs["tvg-logo"]),
                epgChannelID: nonEmpty(pendingAttrs["tvg-id"]),
                categoryID: categoryID,
                hasArchiveFlag: hasCatchup,
                archiveDays: catchupDays,
                // Credential-bearing. In memory only.
                directSource: line,
                playlist: playlist))

            pendingAttrs = [:]
            pendingName = nil
            pendingGroup = nil
        }

        return Parsed(header: header, categories: categories, channels: channels,
                      skippedEntries: skipped)
    }

    // MARK: Pieces

    static func parseHeader(_ line: String) -> Header {
        var header = Header(hasTag: true)
        for (key, value) in attributes(in: line) where !value.isEmpty {
            switch key.lowercased() {
            case "url-tvg", "x-tvg-url":
                // Either attribute may carry a comma-separated list of guides.
                for url in value.split(separator: ",") {
                    let trimmed = url.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { header.guideURLs.append(trimmed) }
                }
            case "tvg-shift":
                // Declared in hours. The rest of this app works in minutes.
                if let hours = Double(value) { header.declaredShiftMinutes = Int(hours * 60) }
            default:
                break
            }
        }
        return header
    }

    static func parseExtInf(_ line: String) -> (attributes: [String: String], title: String) {
        // Named `found` rather than `attributes`, which is the name of the parser two lines below
        // and would shadow it inside this function.
        var found: [String: String] = [:]
        var title = ""

        // Everything after the first comma outside a quoted value is the display name.
        let body = String(line.dropFirst("#EXTINF:".count))
        var inQuotes = false
        var splitIndex: String.Index?
        for index in body.indices {
            let character = body[index]
            if character == "\"" { inQuotes.toggle(); continue }
            if character == ",", !inQuotes { splitIndex = index; break }
        }

        if let splitIndex {
            found = M3U.attributes(in: String(body[body.startIndex..<splitIndex]))
            title = String(body[body.index(after: splitIndex)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            found = M3U.attributes(in: body)
        }

        // A quoted title is legal in the wild and the quotes are not part of the name.
        if title.hasPrefix("\"") && title.hasSuffix("\"") && title.count > 1 {
            title = String(title.dropFirst().dropLast())
        }
        return (found, title)
    }

    /// Pulls `key="value"` pairs. Unquoted values are tolerated because they occur.
    static func attributes(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        var index = text.startIndex

        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            // Walk back over the key.
            let keyEnd = equals
            var keyStart = equals
            while keyStart > text.startIndex {
                let previous = text.index(before: keyStart)
                let character = text[previous]
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    keyStart = previous
                } else { break }
            }
            let key = String(text[keyStart..<keyEnd])

            var valueStart = text.index(after: equals)
            var value = ""
            if valueStart < text.endIndex, text[valueStart] == "\"" {
                valueStart = text.index(after: valueStart)
                if let closing = text[valueStart...].firstIndex(of: "\"") {
                    value = String(text[valueStart..<closing])
                    index = text.index(after: closing)
                } else {
                    value = String(text[valueStart...])
                    index = text.endIndex
                }
            } else {
                // Unquoted: runs to the next whitespace.
                var end = valueStart
                while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
                value = String(text[valueStart..<end])
                index = end
            }
            if !key.isEmpty { found[key.lowercased()] = value }
            if index <= keyEnd { index = text.index(after: keyEnd) }
        }
        return found
    }

    /// A URL's identity. FNV-1a, chosen because it is short, stable across runs and processes, and
    /// trivially re-implementable — a Swift `hashValue` is seeded per process and would change every
    /// launch, which would orphan every favourite.
    public static func stableID(for text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3   // 1099511628211, FNV-1a's 64-bit prime
        }
        return Int(bitPattern: UInt(hash))
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "ungrouped" : collapsed
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - The provider

/// A playlist reached over the network. The URL is the credential, so it is held, never logged, and
/// never placed in the library index.
public struct M3UPlaylistClient: ChannelProvider {
    public let id: PlaylistID
    public let name: String
    private let url: URL
    private let session: URLSession
    private let userAgent: String

    public init(id: PlaylistID, name: String, url: URL,
                userAgent: String = "IPTVMac/1.0", session: URLSession = .shared) {
        self.id = id
        self.name = name
        self.url = url
        self.userAgent = userAgent
        self.session = session
    }

    public func loadCatalog() async throws -> Catalog {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlaylistError.httpStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw PlaylistError.unreadableBody
        }

        let parsed = M3U.parse(text, playlist: id)
        guard !parsed.channels.isEmpty else { throw PlaylistError.noChannels }
        return Catalog(categories: parsed.categories, channels: parsed.channels)
    }

    public func liveURL(for channel: Channel, format: String) -> URL? {
        channel.directSource.flatMap(URL.init(string:))
    }

    /// An M3U playlist's catch-up is the provider's business: some embed `catchup-source`
    /// templates, most simply serve the archive at the same URL with a time parameter. Absent a
    /// template there is nothing honest to construct.
    public func catchUpURL(for channel: Channel, start: Date,
                           durationMinutes: Int, format: String) -> URL? { nil }
}

public enum PlaylistError: LocalizedError {
    case httpStatus(Int)
    case unreadableBody
    case noChannels

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "The playlist answered with HTTP \(code)."
        case .unreadableBody: return "The playlist was not readable as text."
        case .noChannels: return "The playlist contained no usable channels."
        }
    }
}
