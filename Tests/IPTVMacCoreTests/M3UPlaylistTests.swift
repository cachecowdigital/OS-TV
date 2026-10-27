import XCTest
@testable import IPTVMacCore

/// The M3U front door. Xtream answers with JSON and everything it returns is well-shaped; an M3U
/// provider answers with a text file whose conventions are half-standardised, indifferently encoded
/// and sometimes wrong. So this file tests two separate things: that the documented attributes land
/// on the right fields, and that the parser degrades instead of throwing, because a playlist with
/// one broken entry is still a playlist.
///
/// Identity gets the most attention, because it is the part that cannot be fixed later: favourites
/// and recents are keyed on it, and a provider that renumbers its file must not orphan them.
final class M3UPlaylistTests: XCTestCase {

    private let playlist = PlaylistID(rawValue: "m3u-test")

    private let sample = """
    #EXTM3U url-tvg="http://guide.example/xmltv.xml.gz" tvg-shift="-2.5"
    #EXTINF:-1 tvg-id="sportsnet.on.ca" tvg-name="SportsNet Ontario" tvg-logo="http://logo.example/sn.png" group-title="Canada Sports" tvg-chno="42" catchup="default" catchup-days="7",SportsNet Ontario HD
    http://example.test/live/one/2001.ts
    #EXTGRP:News
    #EXTINF:-1 tvg-id="cp24.ca" group-title="ignored-because-extgrp-wins",CP24
    http://example.test/live/one/2002.ts
    #EXTINF:0,No Attributes At All
    http://example.test/plain/3002.ts
    """

    // MARK: Header

    func testHeaderCarriesTheGuideAndTheDeclaredShift() {
        let parsed = M3U.parse(sample, playlist: playlist)
        XCTAssertTrue(parsed.header.hasTag)
        XCTAssertEqual(parsed.header.guideURLs, ["http://guide.example/xmltv.xml.gz"])
        XCTAssertEqual(parsed.header.declaredShiftMinutes, -150,
                       "tvg-shift is declared in hours and this app works in minutes")
    }

    func testMultipleGuideURLsAreAllKept() {
        let parsed = M3U.parse(
            "#EXTM3U x-tvg-url=\"http://a.example/1.xml,http://b.example/2.xml\"",
            playlist: playlist)
        XCTAssertEqual(parsed.header.guideURLs, ["http://a.example/1.xml", "http://b.example/2.xml"])
    }

    func testAPlaylistWithoutTheTagStillParses() {
        let parsed = M3U.parse("#EXTINF:-1,Bare\nhttp://example.test/x.ts", playlist: playlist)
        XCTAssertFalse(parsed.header.hasTag)
        XCTAssertEqual(parsed.channels.count, 1, "a missing #EXTM3U must not discard the entries")
    }

    // MARK: Entries

    func testEveryAttributeLandsOnTheRightField() throws {
        let channel = try XCTUnwrap(M3U.parse(sample, playlist: playlist).channels.first)
        XCTAssertEqual(channel.name, "SportsNet Ontario HD")
        XCTAssertEqual(channel.epgChannelID, "sportsnet.on.ca")
        XCTAssertEqual(channel.iconURL, "http://logo.example/sn.png")
        XCTAssertEqual(channel.number, 42, "tvg-chno is the channel number when present")
        XCTAssertEqual(channel.categoryID, "canada-sports")
        XCTAssertTrue(channel.hasArchive, "catchup plus catchup-days means the archive is usable")
        XCTAssertEqual(channel.archiveDays, 7)
        XCTAssertEqual(channel.directSource, "http://example.test/live/one/2001.ts")
        XCTAssertEqual(channel.playlist, playlist, "the origin must be stamped on every channel")
    }

    func testAGroupDirectiveAppliesToTheNextEntryOnly() throws {
        let channels = M3U.parse(sample, playlist: playlist).channels
        XCTAssertEqual(channels.count, 3)
        XCTAssertEqual(channels[1].categoryID, "news",
                       "#EXTGRP is more specific than group-title, so it wins for its own entry")
        XCTAssertEqual(channels[2].categoryID, "ungrouped",
                       "and must not leak onto the entry after it")
    }

    func testAChannelWithNoAttributesStillWorks() throws {
        let channels = M3U.parse(sample, playlist: playlist).channels
        let bare = try XCTUnwrap(channels.last)
        XCTAssertEqual(bare.name, "No Attributes At All")
        XCTAssertNil(bare.epgChannelID)
        XCTAssertNil(bare.iconURL)
        XCTAssertFalse(bare.hasArchive)
        XCTAssertEqual(bare.number, 3, "a missing number falls back to position in the file")
    }

    // MARK: Identity, which cannot be fixed later

    func testIdentityComesFromTheURLAndNotFromPosition() {
        // The same three entries as `sample`, in a different order and therefore numbered
        // differently. Reversing the raw lines would instead orphan every URL against its #EXTINF,
        // which tests the line reader rather than identity.
        let reordered = """
        #EXTM3U url-tvg="http://guide.example/xmltv.xml.gz" tvg-shift="-2.5"
        #EXTINF:0,No Attributes At All
        http://example.test/plain/3002.ts
        #EXTGRP:News
        #EXTINF:-1 tvg-id="cp24.ca",CP24
        http://example.test/live/one/2002.ts
        #EXTINF:-1 tvg-id="sportsnet.on.ca" tvg-logo="http://logo.example/sn.png" group-title="Canada Sports" tvg-chno="42" catchup="default" catchup-days="7",SportsNet Ontario HD
        http://example.test/live/one/2001.ts
        """

        let forwards = M3U.parse(sample, playlist: playlist).channels
        let shuffled = M3U.parse(reordered, playlist: playlist).channels

        XCTAssertEqual(forwards.count, shuffled.count)
        XCTAssertEqual(Set(forwards.map { $0.streamID }), Set(shuffled.map { $0.streamID }),
                       "reordering or renumbering a provider's file must not change who a channel is")
        let numberBefore = forwards.first { $0.name == "No Attributes At All" }?.number
        let numberAfter = shuffled.first { $0.name == "No Attributes At All" }?.number
        XCTAssertNotEqual(numberBefore, numberAfter,
                          "the position really did change, so the identity test above means something")
    }

    func testTheHashIsTheDocumentedAlgorithmNotAProcessSeed() {
        let parsed = M3U.parse(sample, playlist: playlist)
        let byURL = Dictionary(uniqueKeysWithValues: parsed.channels.map { ($0.directSource ?? "", $0.streamID) })
        XCTAssertEqual(byURL["http://example.test/live/one/2001.ts"], -2371428345925374866,
                       "FNV-1a 64, recomputed independently: a per-process hash would change every launch and orphan every favourite")
        XCTAssertEqual(byURL["http://example.test/live/one/2002.ts"], 4139938922535026293)
    }

    func testTheSameStreamIDInTwoPlaylistsStaysTwoIdentities() {
        let other = PlaylistID(rawValue: "other-m3u")
        let a = M3U.parse(sample, playlist: playlist).channels[0]
        let b = M3U.parse(sample, playlist: other).channels[0]
        XCTAssertEqual(a.streamID, b.streamID, "the same file yields the same provider id")
        XCTAssertNotEqual(a.key, b.key, "but the identity is namespaced by playlist")
    }

    // MARK: Degrading rather than throwing

    func testUnusableEntriesAreCountedAndSkipped() {
        let messy = """
        #EXTM3U
        #EXTINF:-1,Has No URL
        #EXTINF:-1,Good One
        http://example.test/good.ts
        not-a-url-at-all
        http://example.test/orphan.ts
        """
        let parsed = M3U.parse(messy, playlist: playlist)
        XCTAssertEqual(parsed.channels.count, 1, "only the entry with both a name and a URL is usable")
        XCTAssertEqual(parsed.channels.first?.name, "Good One")
        XCTAssertGreaterThanOrEqual(parsed.skippedEntries, 1,
                                    "and the losses are reported rather than silently swallowed")
    }

    func testGroupsAreDeduplicatedIntoCategories() {
        let parsed = M3U.parse(sample, playlist: playlist)
        let sports = parsed.categories.filter { $0.id == "canada-sports" }
        XCTAssertEqual(sports.count, 1, "one category per group, however many channels use it")
        XCTAssertEqual(sports.first?.name, "Canada Sports", "the display name keeps its original form")
        XCTAssertEqual(sports.first?.playlist, playlist)
    }

    func testAQuotedTitleIsUnwrapped() {
        let parsed = M3U.parse("#EXTINF:-1 tvg-id=\"x\",\"A Quoted Name\"\nhttp://example.test/q.ts",
                               playlist: playlist)
        XCTAssertEqual(parsed.channels.first?.name, "A Quoted Name")
    }

    func testACommaInsideAQuotedValueIsNotTheTitleBreak() {
        let parsed = M3U.parse(
            "#EXTINF:-1 group-title=\"News, Live\",Real Name\nhttp://example.test/c.ts",
            playlist: playlist)
        XCTAssertEqual(parsed.channels.first?.name, "Real Name")
        XCTAssertEqual(parsed.channels.first?.categoryID, "news-live")
    }

    func testAnEmptyPlaylistIsEmptyRatherThanBroken() {
        let parsed = M3U.parse("#EXTM3U", playlist: playlist)
        XCTAssertTrue(parsed.channels.isEmpty)
        XCTAssertTrue(parsed.categories.isEmpty)
        XCTAssertEqual(parsed.skippedEntries, 0, "there was nothing to lose")
    }
}
