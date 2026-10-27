//
//  XMLTVParserTests.swift
//  IPTVMacCoreTests
//

import XCTest
import IPTVMacCore

final class XMLTVParserTests: XCTestCase {

    // Epochs below were confirmed with:
    //   date -u -j -f "%Y-%m-%d %H:%M:%S" "2026-10-14 17:30:00" +%s   → 1791999000
    //   date -u -r 1791999000                                          → 2026-10-14 17:30:00
    private enum Epoch {
        static let t1500: TimeInterval = 1791990000  // 2026-10-14 15:00:00 UTC
        static let t1600: TimeInterval = 1791993600  // 2026-10-14 16:00:00 UTC
        static let t1630: TimeInterval = 1791995400  // 2026-10-14 16:30:00 UTC
        static let t1700: TimeInterval = 1791997200  // 2026-10-14 17:00:00 UTC
        static let t1730: TimeInterval = 1791999000  // 2026-10-14 17:30:00 UTC
        static let t1800: TimeInterval = 1792000800  // 2026-10-14 18:00:00 UTC
        static let t1900: TimeInterval = 1792004400  // 2026-10-14 19:00:00 UTC
        static let t2000: TimeInterval = 1792008000  // 2026-10-14 20:00:00 UTC
        static let t2100: TimeInterval = 1792011600  // 2026-10-14 21:00:00 UTC
        static let t2130: TimeInterval = 1792013400  // 2026-10-14 21:30:00 UTC
        static let t2200: TimeInterval = 1792015200  // 2026-10-14 22:00:00 UTC
    }

    // MARK: - 1. Timestamp formats

    func testAllFourTimestampFormatsParseToTheCorrectUTCInstant() {
        // Zone offset present.
        let utcOffset = XMLTVTime.parse("20261014173000 +0000")
        XCTAssertEqual(utcOffset?.timeIntervalSince1970, Epoch.t1730)

        // Non-UTC offset: 17:30 at -0400 is 21:30 UTC.
        let negativeOffset = XMLTVTime.parse("20261014173000 -0400")
        XCTAssertEqual(negativeOffset?.timeIntervalSince1970, Epoch.t2130)

        // No zone at all: assume UTC.
        let bare = XMLTVTime.parse("20261014173000")
        XCTAssertEqual(bare?.timeIntervalSince1970, Epoch.t1730)

        // No seconds.
        let noSeconds = XMLTVTime.parse("202610141730 +0000")
        XCTAssertEqual(noSeconds?.timeIntervalSince1970, Epoch.t1730)

        // All four land on the instants the shell reported.
        XCTAssertEqual(utcOffset, bare)
        XCTAssertEqual(utcOffset, noSeconds)
        // 17:30 at -0400 is 21:30 UTC.
        XCTAssertEqual(negativeOffset, Date(timeIntervalSince1970: Epoch.t2130))
    }

    func testTimestampParserRejectsGarbageAndHonoursAssumeUTC() {
        XCTAssertNil(XMLTVTime.parse(nil))
        XCTAssertNil(XMLTVTime.parse(""))
        XCTAssertNil(XMLTVTime.parse("    "))
        XCTAssertNil(XMLTVTime.parse("not a date"))
        XCTAssertNil(XMLTVTime.parse("20261014173000 +00x0"))
        XCTAssertNil(XMLTVTime.parse("20261314173000 +0000"))   // month 13
        XCTAssertNil(XMLTVTime.parse("20260230120000 +0000"))   // 30 February
        XCTAssertNil(XMLTVTime.parse("20261014173000 +0000 junk"))

        // Explicitly refusing the zone-less fallback.
        XCTAssertNil(XMLTVTime.parse("20261014173000", assumeUTC: false))
        XCTAssertEqual(
            XMLTVTime.parse("20261014173000 +0000", assumeUTC: false)?.timeIntervalSince1970,
            Epoch.t1730
        )
    }

    // MARK: - 2. Grouping

    private static let guide = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE tv SYSTEM "xmltv.dtd">
    <tv generator-info-name="xtream">
      <channel id="ABCKYUR.us"><display-name>ABC 13</display-name></channel>
      <channel id="CBCTOR.ca"><display-name>CBC Toronto</display-name></channel>

      <programme start="20261014163000 +0000" stop="20261014170000 +0000" channel="ABCKYUR.us">
        <title lang="en">Inside Edition</title>
        <sub-title lang="en">Wednesday</sub-title>
        <desc lang="en">Daytime magazine show.</desc>
        <category lang="en">News</category>
      </programme>

      <programme start="20261014170000 +0000" stop="20261014180000 +0000" channel="ABCKYUR.us">
        <title lang="en">World News Tonight</title>
        <desc lang="en">Evening bulletin.</desc>
      </programme>

      <programme start="20261014200000 +0000" stop="20261014210000 +0000" channel="ABCKYUR.us">
        <title lang="en">Primetime Special</title>
        <desc lang="en">Two hour special.</desc>
      </programme>

      <programme start="20261014173000 +0000" stop="20261014180000 +0000" channel="CBCTOR.ca">
        <title lang="en">Coronation Street</title>
        <desc lang="en">Long running drama.</desc>
      </programme>

      <programme start="20261014210000 +0000" stop="20261014220000 +0000" channel="CBCTOR.ca">
        <title lang="en">Hockey Night</title>
        <desc lang="en">Live coverage.</desc>
      </programme>
    </tv>
    """

    func testGuideGroupsTwoChannelsAndFiveProgrammes() throws {
        let grouped = try XMLTVParser.parse(data: Data(Self.guide.utf8), skipEndedBefore: nil)

        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(Set(grouped.keys), ["ABCKYUR.us", "CBCTOR.ca"])

        let abc = try XCTUnwrap(grouped["ABCKYUR.us"])
        XCTAssertEqual(abc.count, 3)
        XCTAssertEqual(abc.map(\.title), ["Inside Edition", "World News Tonight", "Primetime Special"])
        XCTAssertEqual(abc.map(\.detail), ["Daytime magazine show.", "Evening bulletin.", "Two hour special."])
        XCTAssertEqual(abc.map(\.channelID), ["ABCKYUR.us", "ABCKYUR.us", "ABCKYUR.us"])

        XCTAssertEqual(abc[0].start.timeIntervalSince1970, Epoch.t1630)
        XCTAssertEqual(abc[0].stop.timeIntervalSince1970, Epoch.t1700)
        XCTAssertEqual(abc[1].start.timeIntervalSince1970, Epoch.t1700)
        XCTAssertEqual(abc[1].stop.timeIntervalSince1970, Epoch.t1800)
        XCTAssertEqual(abc[2].start.timeIntervalSince1970, Epoch.t2000)
        XCTAssertEqual(abc[2].stop.timeIntervalSince1970, Epoch.t2100)

        let cbc = try XCTUnwrap(grouped["CBCTOR.ca"])
        XCTAssertEqual(cbc.count, 2)
        XCTAssertEqual(cbc.map(\.title), ["Coronation Street", "Hockey Night"])
        XCTAssertEqual(cbc.map(\.detail), ["Long running drama.", "Live coverage."])
        XCTAssertEqual(cbc[0].start.timeIntervalSince1970, Epoch.t1730)
        XCTAssertEqual(cbc[0].stop.timeIntervalSince1970, Epoch.t1800)
        XCTAssertEqual(cbc[1].start.timeIntervalSince1970, Epoch.t2100)
        XCTAssertEqual(cbc[1].stop.timeIntervalSince1970, Epoch.t2200)

        // Hashable/Equatable round-trip.
        XCTAssertEqual(abc[0], XMLTVProgramme(
            channelID: "ABCKYUR.us",
            title: "Inside Edition",
            detail: "Daytime magazine show.",
            start: Date(timeIntervalSince1970: Epoch.t1630),
            stop: Date(timeIntervalSince1970: Epoch.t1700)
        ))
    }

    // MARK: - 3. Cutoff

    func testSkipEndedBeforeDropsFinishedProgrammesButKeepsTheRunningOne() throws {
        let guide = """
        <tv>
          <programme start="20261014150000 +0000" stop="20261014160000 +0000" channel="ABCKYUR.us">
            <title>Morning Show</title>
            <desc>Already finished.</desc>
          </programme>
          <programme start="20261014170000 +0000" stop="20261014190000 +0000" channel="ABCKYUR.us">
            <title>Live Match</title>
            <desc>Running across the cutoff.</desc>
          </programme>
          <programme start="20261014200000 +0000" stop="20261014220000 +0000" channel="ABCKYUR.us">
            <title>Late Night</title>
            <desc>Still to come.</desc>
          </programme>
        </tv>
        """

        let cutoff = Date(timeIntervalSince1970: Epoch.t1800)  // 18:00 UTC
        let grouped = try XMLTVParser.parse(data: Data(guide.utf8), skipEndedBefore: cutoff)
        let kept = try XCTUnwrap(grouped["ABCKYUR.us"])

        XCTAssertEqual(kept.count, 2)
        XCTAssertFalse(kept.contains { $0.title == "Morning Show" }, "finished programme should be dropped")
        XCTAssertEqual(kept.map(\.title), ["Live Match", "Late Night"])

        // The programme straddling the cutoff is exactly the interesting case:
        // it started before the cutoff and stops after it.
        let running = try XCTUnwrap(kept.first { $0.title == "Live Match" })
        XCTAssertLessThan(running.start, cutoff)
        XCTAssertGreaterThan(running.stop, cutoff)
        XCTAssertTrue(running.start <= cutoff && cutoff < running.stop)

        // Without a cutoff all three survive.
        let unfiltered = try XMLTVParser.parse(data: Data(guide.utf8), skipEndedBefore: nil)
        XCTAssertEqual(unfiltered["ABCKYUR.us"]?.count, 3)
    }

    // MARK: - 4. Entities

    func testEntitiesAndAccentedCharactersRoundTripInTitle() throws {
        let guide = """
        <tv>
          <programme start="20261014163000 +0000" stop="20261014170000 +0000" channel="ABCKYUR.us">
            <title lang="en">Ben &amp; Jerry&apos;s Caf&#233; &#8212; Na&#239;ve</title>
            <desc lang="en">&lt;3 &amp; more</desc>
          </programme>
        </tv>
        """

        let grouped = try XMLTVParser.parse(data: Data(guide.utf8), skipEndedBefore: nil)
        let programme = try XCTUnwrap(grouped["ABCKYUR.us"]?.first)

        // The raw entity text must never leak through.
        XCTAssertFalse(programme.title.contains("&amp;"))
        XCTAssertFalse(programme.title.contains("&#233;"))

        XCTAssertEqual(programme.title, "Ben & Jerry's Café — Naïve")
        XCTAssertTrue(programme.title.contains("&"), "decoded ampersand expected")
        XCTAssertTrue(programme.title.contains("é"), "decoded accented character expected")
        XCTAssertTrue(programme.title.contains("ï"), "decoded accented character expected")
        XCTAssertEqual(programme.detail, "<3 & more")
    }

    // MARK: - 5. Malformed input

    func testTruncatedAndGarbageXMLThrowInsteadOfReturningEmpty() {
        let truncated = """
        <tv>
          <programme start="20261014163000 +0000" stop="20261014170000 +0000" channel="ABCKYUR.us">
            <title>Inside Edition
        """

        for (label, body) in [("garbage", "this is not xml at all"), ("truncated", truncated), ("empty", "")] {
            do {
                let grouped = try XMLTVParser.parse(data: Data(body.utf8), skipEndedBefore: nil)
                XCTFail("\(label) input should have thrown, returned \(grouped)")
            } catch let error as XMLTVError {
                guard case .malformed(let reason) = error else {
                    return XCTFail("\(label) threw an unexpected XMLTVError case")
                }
                XCTAssertFalse(reason.isEmpty, "\(label) should carry a readable reason")
                XCTAssertNotNil(error.errorDescription)
                XCTAssertTrue((error.errorDescription ?? "").contains("Malformed XMLTV document"))
                XCTAssertTrue((error.errorDescription ?? "").count > "Malformed XMLTV document: ".count)
            } catch {
                XCTFail("\(label) threw \(type(of: error)) instead of XMLTVError: \(error)")
            }
        }
    }

    // MARK: - 6. Unusable programmes are dropped, not fatal

    func testProgrammesWithBadDatesOrNoChannelAreSilentlyDropped() throws {
        let guide = """
        <tv>
          <programme start="garbage" stop="20261014170000 +0000" channel="ABCKYUR.us">
            <title>Bad Start</title>
          </programme>
          <programme start="20261014163000 +0000" stop="" channel="ABCKYUR.us">
            <title>Bad Stop</title>
          </programme>
          <programme start="20261014163000 +0000" stop="20261014170000 +0000">
            <title>No Channel</title>
          </programme>
          <programme start="20261014163000 +0000" stop="20261014170000 +0000" channel="ABCKYUR.us">
            <title>Good One</title>
            <desc>Fine.</desc>
          </programme>
        </tv>
        """

        let grouped = try XMLTVParser.parse(data: Data(guide.utf8), skipEndedBefore: nil)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped["ABCKYUR.us"]?.map(\.title), ["Good One"])
        XCTAssertEqual(grouped["ABCKYUR.us"]?.first?.detail, "Fine.")
    }
}
