import XCTest
@testable import IPTVMacCore

/// Why this file exists: `stream_id` is unique only within one portal. Both of the owner's
/// subscriptions carry a channel numbered 647, so any collection keyed on a bare Int merges two
/// genuinely different channels into one, and which one survives depends on load order. These tests
/// pin the namespacing that prevents that, together with the playlist policy that has to hold
/// around it: off means off, reordering is display order and not identity, and a profile narrows
/// visibility without ever resurrecting a playlist the owner switched off.
final class ProviderIdentityTests: XCTestCase {

    private let first = PlaylistID(rawValue: "playlist-one")
    private let second = PlaylistID(rawValue: "playlist-two")

    private func channel(_ streamID: Int, _ name: String,
                         playlist: PlaylistID = .unassigned) -> Channel {
        Channel(streamID: streamID, number: streamID, name: name, playlist: playlist)
    }

    private func playlist(_ id: PlaylistID, _ name: String,
                          enabled: Bool = true, order: Int = 0) -> Playlist {
        Playlist(id: id, name: name,
                 kind: .xtream(host: name.lowercased() + ".example"),
                 isEnabled: enabled, order: order)
    }

    // MARK: The collision itself

    func testTheSameStreamIDOnTwoPlaylistsIsTwoIdentities() {
        let a = channel(647, "SportsNet East", playlist: first)
        let b = channel(647, "SportsNet East", playlist: second)

        XCTAssertNotEqual(a.key, b.key, "the same stream id on two playlists must not share a key")
        XCTAssertEqual(Set([a.key, b.key]).count, 2)
        XCTAssertNotEqual(a, b, "identical-looking channels from different portals are different channels")
        XCTAssertEqual(a.key.streamID, b.key.streamID, "the provider id is still the provider id")
    }

    func testStampingAPlaylistPreservesEverythingElse() {
        let plain = channel(647, "SportsNet East")
        XCTAssertEqual(plain.playlist, .unassigned)

        let stamped = plain.inPlaylist(first)
        XCTAssertEqual(stamped.playlist, first)
        XCTAssertEqual(stamped.streamID, plain.streamID)
        XCTAssertEqual(stamped.name, plain.name)
        XCTAssertEqual(stamped.number, plain.number)
        XCTAssertEqual(stamped.key, ChannelKey(playlist: first, streamID: 647))
    }

    func testCategoryKeysAreNamespacedToo() {
        let a = ChannelCategory(id: "12", name: "Sports", playlist: first)
        let b = ChannelCategory(id: "12", name: "Sports", playlist: second)
        XCTAssertNotEqual(a.key, b.key)
    }

    // MARK: Off means off

    func testADisabledPlaylistLeavesTheEnabledSetButKeepsItsPlace() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))
        XCTAssertEqual(index.enabledPlaylists.count, 2)

        index.setEnabled(first, false)
        XCTAssertEqual(index.enabledPlaylists.map(\.id), [second])
        XCTAssertEqual(index.playlists.count, 2, "switching off must not delete")
        XCTAssertEqual(index.playlist(first)?.order, 0, "and must not reorder")
    }

    func testAProfileCannotResurrectADisabledPlaylist() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))
        let profile = Profile(id: .standard, name: "Owner", visiblePlaylistIDs: [first, second])
        index.profiles = [profile]
        index.activeProfileID = .standard
        index.setEnabled(second, false)

        XCTAssertEqual(index.enabledPlaylists.map(\.id), [first],
                       "a profile listing a disabled playlist must not bring it back")
    }

    func testAProfileNarrowsVisibility() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))
        index.profiles = [Profile(id: .standard, name: "Kids", visiblePlaylistIDs: [first])]
        index.activeProfileID = .standard

        XCTAssertEqual(index.enabledPlaylists.map(\.id), [first])
    }

    func testAnEmptyProfileVisibilityListMeansEverything() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))
        index.profiles = [Profile(id: .standard, name: "Owner")]
        index.activeProfileID = .standard

        XCTAssertEqual(index.enabledPlaylists.count, 2)
    }

    // MARK: Ordering is not identity

    func testMovingAPlaylistIsDisplayOnly() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))
        let favourite = channel(647, "SportsNet East", playlist: first).key

        XCTAssertTrue(index.move(second, by: -1))
        XCTAssertEqual(index.orderedPlaylists.map(\.id), [second, first])
        XCTAssertEqual(index.playlist(first)?.id, first, "identity survives a reorder")
        XCTAssertEqual(favourite.playlist, first, "so does a favourite keyed on it")
        XCTAssertEqual(index.orderedPlaylists.map(\.order), [0, 1], "and order stays dense")
    }

    func testMovingPastTheEndIsRefusedWithoutCorruption() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))

        XCTAssertFalse(index.move(first, by: -1), "first cannot move up")
        XCTAssertFalse(index.move(second, by: 1), "last cannot move down")
        XCTAssertEqual(index.orderedPlaylists.map(\.id), [first, second])
    }

    func testAddingAppendsToTheEnd() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))
        XCTAssertEqual(index.orderedPlaylists.map(\.id), [first, second])
    }

    func testRemovingAPlaylistAlsoRemovesItFromProfiles() {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.add(playlist(second, "Backup"))
        index.profiles = [Profile(id: .standard, name: "Owner", visiblePlaylistIDs: [first, second])]

        index.remove(first)

        XCTAssertEqual(index.playlists.map(\.id), [second])
        XCTAssertEqual(index.profiles[0].visiblePlaylistIDs, [second],
                       "a dangling id in a profile would be a bug waiting to happen")
    }

    // MARK: Shift resolution

    func testAManualShiftBeatsAMeasuredOne() {
        var p = playlist(first, "Primary")
        p.epgDetectedShiftMinutes = -45
        XCTAssertEqual(p.effectiveShiftMinutes, -45, "a measured shift is used when nothing is set")

        p.epgShiftMinutes = 60
        XCTAssertEqual(p.effectiveShiftMinutes, 60, "an explicit choice wins over the measurement")
    }

    // MARK: Persistence, and what must not be in it

    func testTheIndexRoundTripsThroughJSON() throws {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        var backup = playlist(second, "Backup", enabled: false)
        backup.epg = .xmltv(id: "epg-1", displayURL: "guide.example/xmltv.php")
        backup.legacyGuideCacheKey = "primary-guide-v1"
        index.add(backup)
        index.epgSources = [EPGSourceRecord(id: "epg-1", name: "Shared guide",
                                           displayURL: "guide.example/xmltv.php")]
        index.profiles = [Profile(id: .standard, name: "Owner", visiblePlaylistIDs: [first])]
        index.activeProfileID = .standard

        let data = try JSONEncoder().encode(index)
        let restored = try JSONDecoder().decode(LibraryIndex.self, from: data)

        XCTAssertEqual(restored.playlists.count, 2)
        XCTAssertEqual(restored.playlist(second)?.isEnabled, false)
        XCTAssertEqual(restored.playlist(second)?.legacyGuideCacheKey, "primary-guide-v1")
        XCTAssertEqual(restored.playlists.first(where: { $0.id == second })?.epg.displayTarget,
                       "guide.example/xmltv.php")
        XCTAssertEqual(restored.profiles[0].visiblePlaylistIDs, [first])
        XCTAssertEqual(restored.enabledPlaylists.map(\.id), [first])
    }

    func testTheIndexHasNoPlaceForACredential() throws {
        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        let json = String(data: try JSONEncoder().encode(index), encoding: .utf8) ?? ""

        for forbidden in ["password", "fullURL", "username\"", "token", "secret"] {
            XCTAssertFalse(json.contains(forbidden),
                           "the library index must never gain a home for a credential (found \(forbidden))")
        }
        // And the secret type is separately encodable, because that is where credentials live.
        let secret = PlaylistSecret(password: "p", fullURL: "http://portal.example/get.php?u=x&p=y")
        XCTAssertNotNil(try? JSONEncoder().encode(secret))
    }

    func testLibraryStorePersistsThroughDefaults() {
        let suite = "jabcorptv.tests.identity." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var index = LibraryIndex()
        index.add(playlist(first, "Primary"))
        index.setEnabled(first, false)
        LibraryStore(defaults: defaults, key: "k").save(index)

        let reloaded = LibraryStore(defaults: defaults, key: "k").load()
        XCTAssertEqual(reloaded.playlists.count, 1)
        XCTAssertEqual(reloaded.playlist(first)?.isEnabled, false)
    }

    func testLibraryStoreReturnsAnEmptyIndexRatherThanCrashingOnGarbage() {
        let suite = "jabcorptv.tests.garbage." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "k")

        let index = LibraryStore(defaults: defaults, key: "k").load()
        XCTAssertTrue(index.playlists.isEmpty, "a corrupt index degrades to empty, not to a crash")
    }
}
