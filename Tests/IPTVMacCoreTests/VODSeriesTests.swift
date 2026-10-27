import XCTest
@testable import IPTVMacCore

/// Decode tests built from real `get_vod_streams` / `get_series` / `get_series_info` responses
/// captured live from a provider that actually carries VOD and series content — not written from
/// the Xtream docs alone, which disagree with each other on some of these field names.
final class VODSeriesTests: XCTestCase {

    func testVODStreamDecodesANormalMovie() throws {
        let json = """
        {
          "num": 1,
          "name": "Superman (1941)",
          "stream_type": "movie",
          "stream_id": 2201782,
          "stream_icon": "http://example.test/poster.jpg",
          "rating": "6.9",
          "added": "1773960401",
          "plot": "After The Daily Planet receives a letter from a mad scientist...",
          "category_id": "936",
          "category_ids": [936],
          "container_extension": "mp4",
          "custom_sid": "",
          "direct_source": "http://example.test/play/redacted"
        }
        """.data(using: .utf8)!
        let movie = try JSONDecoder().decode(VODStream.self, from: json)
        XCTAssertEqual(movie.streamID, 2201782)
        XCTAssertEqual(movie.name, "Superman (1941)")
        XCTAssertEqual(movie.categoryID, "936")
        XCTAssertEqual(movie.containerExtension, "mp4")
        XCTAssertEqual(movie.rating, "6.9")
    }

    func testVODStreamFallsBackToMP4WhenContainerExtensionIsMissing() throws {
        let json = """
        { "stream_id": 5, "name": "Untitled" }
        """.data(using: .utf8)!
        let movie = try JSONDecoder().decode(VODStream.self, from: json)
        XCTAssertEqual(movie.containerExtension, "mp4")
    }

    func testSeriesSummaryDecodesCoverAsIconURL() throws {
        let json = """
        {
          "num": 1,
          "name": "The Queen of the South (2011)",
          "series_id": 24292,
          "cover": "http://example.test/series-cover.jpg",
          "plot": "This compelling show tells the story of...",
          "category_id": "912",
          "category_ids": [912],
          "rating": "8"
        }
        """.data(using: .utf8)!
        let series = try JSONDecoder().decode(SeriesSummary.self, from: json)
        XCTAssertEqual(series.seriesID, 24292)
        XCTAssertEqual(series.iconURL, "http://example.test/series-cover.jpg")
        XCTAssertEqual(series.categoryID, "912")
    }

    func testSeriesEpisodeDecodesTheTopLevelSeasonField() throws {
        // The provider puts `season` directly on the episode object (confirmed live), not only
        // nested under `info.season_number` — this pins that so a future refactor can't quietly
        // start reading the wrong one.
        let json = """
        {
          "id": "2588729",
          "episode_num": "1",
          "title": "The Queen of the South (2011) - S01E01 - Run to Live",
          "container_extension": "mp4",
          "season": 1,
          "info": { "season_number": 1, "episode_number": 1 }
        }
        """.data(using: .utf8)!
        let episode = try JSONDecoder().decode(SeriesEpisode.self, from: json)
        XCTAssertEqual(episode.episodeID, 2588729)
        XCTAssertEqual(episode.episodeNumber, 1)
        XCTAssertEqual(episode.season, 1)
        XCTAssertEqual(episode.containerExtension, "mp4")
    }
}
