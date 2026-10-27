//
//  XMLTVParser.swift
//  IPTVMacCore
//
//  Streaming (SAX) XMLTV / EPG parser.
//
//  Real Xtream portals hand back guides measured in tens of megabytes, so this
//  parser deliberately never materialises a DOM and never keeps the raw text of
//  the document: only the per-element character buffer for the handful of leaf
//  elements we actually care about is held at any moment. Memory use is
//  O(programmes kept), not O(document size).
//

import Foundation

// MARK: - Programme

/// A single `<programme>` entry, normalised to UTC `Date`s.
public struct XMLTVProgramme: Sendable, Hashable {
    public let channelID: String
    public let title: String
    public let detail: String
    public let start: Date
    public let stop: Date

    public init(channelID: String, title: String, detail: String, start: Date, stop: Date) {
        self.channelID = channelID
        self.title = title
        self.detail = detail
        self.start = start
        self.stop = stop
    }
}

// MARK: - Parse statistics

/// What the parser did with the document, including what it discarded.
///
/// These counts exist because the drops used to be silent. A programme whose start or stop could
/// not be read was discarded without a word, so a provider that changed its stamp format would
/// shrink the guide with nothing anywhere saying so — and a guide that is quietly smaller looks
/// exactly like a provider that simply has less to say.
public struct XMLTVParseStats: Sendable, Equatable {
    public var kept = 0
    public var droppedBadTimestamps = 0
    public var droppedEnded = 0
    public var droppedNoChannel = 0

    public var droppedTotal: Int { droppedBadTimestamps + droppedEnded + droppedNoChannel }

    public init() {}
}

/// Programmes, plus the counts describing what happened to the rest of the document.
public struct XMLTVParseResult: Sendable {
    public let programmes: [String: [XMLTVProgramme]]
    public let stats: XMLTVParseStats

    public init(programmes: [String: [XMLTVProgramme]], stats: XMLTVParseStats) {
        self.programmes = programmes
        self.stats = stats
    }
}

// MARK: - Error

public enum XMLTVError: LocalizedError {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason):
            return "Malformed XMLTV document: \(reason)"
        }
    }
}

// MARK: - Timestamps

public enum XMLTVTime {

    /// Parses XMLTV timestamps. Accepts every shape the XMLTV DTD allows:
    ///
    ///     "20261014173000 +0000"   zone offset present
    ///     "20261014173000 -0400"   non-UTC offset
    ///     "20261014173000"         no zone, assume UTC
    ///     "202610141730 +0000"     no seconds
    ///
    /// Returns `nil` for empty, non-numeric or out-of-range input rather than
    /// guessing. `assumeUTC == false` additionally rejects zone-less stamps.
    public static func parse(_ raw: String?, assumeUTC: Bool = true) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Leading run of ASCII digits is the stamp; anything after it (if any)
        // is the zone designator, with or without an intervening space.
        var end = trimmed.startIndex
        while end < trimmed.endIndex, isDigit(trimmed[end]) {
            end = trimmed.index(after: end)
        }
        let stamp = trimmed[trimmed.startIndex..<end]
        let rest = trimmed[end...].trimmingCharacters(in: .whitespacesAndNewlines)

        // XMLTV requires at least YYYYMMDDHHMM; seconds are optional.
        guard stamp.count == 12 || stamp.count == 14 else { return nil }

        var offsetSeconds = 0
        if rest.isEmpty {
            guard assumeUTC else { return nil }
        } else {
            guard let offset = zoneOffset(rest) else { return nil }
            offsetSeconds = offset
        }

        let digits = Array(stamp).map { $0.wholeNumberValue ?? 0 }
        let year = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
        let month = digits[4] * 10 + digits[5]
        let day = digits[6] * 10 + digits[7]
        let hour = digits[8] * 10 + digits[9]
        let minute = digits[10] * 10 + digits[11]
        let second = stamp.count == 14 ? digits[12] * 10 + digits[13] : 0

        guard (1970...2200).contains(year),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second),
              let zone = TimeZone(secondsFromGMT: offsetSeconds)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }

        // Reject impossible dates (20260230…) that Foundation would silently
        // roll forward into the following month.
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == year, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute, back.second == second
        else { return nil }

        return date
    }

    // MARK: Helpers

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// `"+0000"`, `"-0400"`, `"+05:30"`, `"Z"`, `"UTC"` → seconds from GMT.
    private static func zoneOffset(_ raw: String) -> Int? {
        let upper = raw.uppercased()
        if upper == "Z" || upper == "UTC" || upper == "GMT" { return 0 }

        guard let signCharacter = raw.first, signCharacter == "+" || signCharacter == "-" else {
            return nil
        }
        let sign = signCharacter == "-" ? -1 : 1

        let body = raw.dropFirst().replacingOccurrences(of: ":", with: "")
        guard body.count == 4, body.allSatisfy({ isDigit($0) }) else { return nil }

        let digits = Array(body).map { $0.wholeNumberValue ?? 0 }
        let hours = digits[0] * 10 + digits[1]
        let minutes = digits[2] * 10 + digits[3]
        guard hours <= 23, minutes <= 59 else { return nil }

        return sign * (hours * 3600 + minutes * 60)
    }
}

// MARK: - Parser

public enum XMLTVParser {

    /// Streams an XMLTV document and returns its programmes grouped by the
    /// XMLTV channel id (`<programme channel="…">`), which callers match against
    /// `Channel.epgChannelID`.
    ///
    /// - Parameters:
    ///   - data: the whole guide. It is handed to `XMLParser` unmodified; the
    ///     parse itself is incremental and never builds a DOM, so a 50 MB guide
    ///     is fine.
    ///   - cutoff: when non-nil, any programme whose `stop` is strictly earlier
    ///     than this instant is discarded. A programme still running at the
    ///     cutoff (started before, stops after) is kept.
    /// - Throws: `XMLTVError.malformed` when the document as a whole is not
    ///   well-formed XML. Individual programmes with a missing or unparseable
    ///   `start`/`stop`, or with no `channel` attribute, are dropped silently.
    public static func parse(data: Data, skipEndedBefore cutoff: Date?) throws -> [String: [XMLTVProgramme]] {
        try parseDetailed(data: data, skipEndedBefore: cutoff).programmes
    }

    /// The same parse, keeping the counts of what was discarded. Callers that surface those counts
    /// should use this one; `parse` remains the plain form for tests and fixtures.
    public static func parseDetailed(data: Data, skipEndedBefore cutoff: Date?) throws -> XMLTVParseResult {
        if data.isEmpty {
            throw XMLTVError.malformed("document is empty")
        }

        let collector = XMLTVCollector(cutoff: cutoff)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        guard parser.parse() else {
            throw XMLTVError.malformed(collector.failureDescription ?? "the document could not be parsed")
        }
        return XMLTVParseResult(programmes: collector.programmes, stats: collector.stats)
    }
}

// MARK: - SAX collector

/// `XMLParserDelegate` is an `@objc` protocol whose conformance requires an
/// `NSObject` subclass. Nothing here escapes `XMLTVParser.parse`, so the
/// collector is not shared and needs no actor isolation: parsing is a pure
/// function that is safe to run on any thread.
private final class XMLTVCollector: NSObject, XMLParserDelegate {

    private struct PendingProgramme {
        var channelID = ""
        var start: Date?
        var stop: Date?
        var title = ""
        var detail = ""
    }

    private let cutoff: Date?
    private(set) var programmes: [String: [XMLTVProgramme]] = [:]
    private(set) var stats = XMLTVParseStats()
    private(set) var failureDescription: String?

    private var pending: PendingProgramme?
    private var capturingElement: String?
    private var textBuffer = ""

    init(cutoff: Date?) {
        self.cutoff = cutoff
    }

    // MARK: Element boundaries

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "programme":
            var programme = PendingProgramme()
            programme.channelID = attributeDict["channel"] ?? ""
            programme.start = XMLTVTime.parse(attributeDict["start"])
            programme.stop = XMLTVTime.parse(attributeDict["stop"])
            pending = programme
            capturingElement = nil
            textBuffer = ""

        case "title", "desc":
            guard pending != nil else { return }
            capturingElement = elementName
            textBuffer = ""

        default:
            break
        }
    }

    /// Text arrives in arbitrary chunks — libxml2 splits at entity and
    /// character-reference boundaries — so buffer and concatenate, then take the
    /// whole run at the closing tag.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturingElement != nil else { return }
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard capturingElement != nil, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        textBuffer += text
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "programme" {
            if let programme = pending { finish(programme) }
            pending = nil
            capturingElement = nil
            textBuffer = ""
            return
        }

        guard let capturing = capturingElement, capturing == elementName, var programme = pending else { return }

        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": programme.title = text
        case "desc": programme.detail = text
        default: break
        }

        pending = programme
        capturingElement = nil
        textBuffer = ""
    }

    // MARK: Bookkeeping

    private func finish(_ programme: PendingProgramme) {
        // A programme with no channel, or without both ends of its window, is
        // unusable: drop it rather than failing the whole guide — but count it, so a provider
        // whose stamp format changes shows up as a number instead of as a quietly thinner guide.
        guard !programme.channelID.isEmpty else {
            stats.droppedNoChannel += 1
            return
        }
        guard let start = programme.start, let stop = programme.stop else {
            stats.droppedBadTimestamps += 1
            return
        }

        if let cutoff = cutoff, stop < cutoff {
            stats.droppedEnded += 1
            return
        }

        stats.kept += 1
        programmes[programme.channelID, default: []].append(
            XMLTVProgramme(
                channelID: programme.channelID,
                title: programme.title,
                detail: programme.detail,
                start: start,
                stop: stop
            )
        )
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // The code carried by `parserError` after a failure is always the
        // generic libxml2 code; the delegate callback is the only place the
        // specific error surfaces.
        let code = (parseError as NSError).code
        let shape = XMLTVCollector.describe(code: code)
        failureDescription = "\(shape) at line \(parser.lineNumber), column \(parser.columnNumber)"
    }

    private static func describe(code: Int) -> String {
        switch code {
        case 1: return "the document could not be parsed"
        case 3: return "unexpected end of document"
        case 4: return "not well-formed XML (no root element found)"
        case 5: return "unexpected end of document (the input looks truncated)"
        case 9: return "the document contains a character that is not valid XML"
        case 42: return "a start tag repeats an attribute"
        case 76: return "an end tag does not match its start tag"
        default: return "XML parse error (code \(code))"
        }
    }
}
