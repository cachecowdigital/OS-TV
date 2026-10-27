import XCTest
@testable import IPTVMacCore

/// `catchUpURL` is the one place the panel's timezone actually matters: the archive stamp is
/// parsed by the panel in ITS own zone (see the comment above the function), so a wrong zone here
/// asks for a window that is however many hours off from the programme the viewer picked.
final class XtreamClientTests: XCTestCase {

    private func client(server: String = "http://example.com:8080") -> XtreamClient {
        XtreamClient(credentials: Credentials(server: server, username: "u", password: "p"))
    }

    func testCatchUpURLStampsInThePanelTimeZoneWhenSet() {
        let c = client()
        c.panelTimeZone = TimeZone(identifier: "America/New_York")
        // 2026-01-05 00:30 UTC is 2026-01-04 19:30 in America/New_York (UTC-5 in January).
        let start = ISO8601DateFormatter().date(from: "2026-01-05T00:30:00Z")!
        let url = c.catchUpURL(streamID: 7, start: start, durationMinutes: 30)
        XCTAssertTrue(url?.absoluteString.contains("2026-01-04:19-30") == true, url?.absoluteString ?? "nil")
    }

    func testCatchUpURLFallsBackToTheViewersZoneWhenThePanelZoneIsUnset() {
        let c = client()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = DateFormatter()
        expected.locale = Locale(identifier: "en_US_POSIX")
        expected.timeZone = .current
        expected.dateFormat = "yyyy-MM-dd:HH-mm"
        let stamp = expected.string(from: start)
        let url = c.catchUpURL(streamID: 7, start: start, durationMinutes: 30)
        XCTAssertTrue(url?.absoluteString.contains(stamp) == true, url?.absoluteString ?? "nil")
    }

    func testCatchUpURLPathCarriesCredentialsStreamIDAndDuration() {
        let c = client()
        let url = c.catchUpURL(streamID: 42, start: Date(), durationMinutes: 90, format: "ts")
        let s = url?.absoluteString ?? ""
        XCTAssertTrue(s.contains("/timeshift/u/p/90/"), s)
        XCTAssertTrue(s.hasSuffix("/42.ts"), s)
    }

    // MARK: - VOD / Series URLs
    //
    // Movies and episodes carry their own container extension from the provider, so unlike
    // live/catch-up there is no format the app chooses — these tests exist to pin the one
    // shape (`/movie/...`, `/series/...`) against a provider confirmed live to use exactly
    // this field name (`container_extension`) and these path prefixes.

    func testVodURLUsesTheMoviesOwnContainerExtension() {
        let c = client()
        let url = c.vodURL(streamID: 2201782, ext: "mkv")
        XCTAssertEqual(url?.absoluteString, "http://example.com:8080/movie/u/p/2201782.mkv")
    }

    func testVodURLFallsBackToMP4WhenTheProviderSentNoExtension() {
        let c = client()
        let url = c.vodURL(streamID: 5, ext: "")
        XCTAssertEqual(url?.absoluteString, "http://example.com:8080/movie/u/p/5.mp4")
    }

    func testEpisodeURLUsesTheEpisodeID() {
        let c = client()
        let url = c.episodeURL(episodeID: 2588729, ext: "mp4")
        XCTAssertEqual(url?.absoluteString, "http://example.com:8080/series/u/p/2588729.mp4")
    }
}
