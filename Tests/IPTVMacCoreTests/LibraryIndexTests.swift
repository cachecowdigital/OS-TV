import XCTest
@testable import IPTVMacCore

/// `LibraryIndex` is what the multi-subscription switcher persists (non-secret: name, host,
/// order, which one is active). The secret half of each subscription never touches this type —
/// it lives in its own Keychain item under `PlaylistID.keychainAccount`, tested separately by
/// construction rather than by reading the real Keychain in a unit test.
final class LibraryIndexTests: XCTestCase {

    func testAddAssignsADenseOrderAfterTheCurrentMax() {
        var index = LibraryIndex()
        let first = Playlist(id: PlaylistID(), name: "Ti1", kind: .xtream(host: "http://a.test"))
        let second = Playlist(id: PlaylistID(), name: "iTV4", kind: .xtream(host: "http://b.test"))
        index.add(first)
        index.add(second)
        XCTAssertEqual(index.orderedPlaylists.map(\.name), ["Ti1", "iTV4"])
    }

    func testRemoveDropsThePlaylistAndAnyProfileVisibility() {
        var index = LibraryIndex()
        let playlist = Playlist(id: PlaylistID(), name: "Ti1", kind: .xtream(host: "http://a.test"))
        index.add(playlist)
        var profile = Profile(name: "Default")
        profile.visiblePlaylistIDs = [playlist.id]
        index.profiles = [profile]

        index.remove(playlist.id)

        XCTAssertTrue(index.playlists.isEmpty)
        XCTAssertTrue(index.profiles[0].visiblePlaylistIDs.isEmpty)
    }

    func testActivePlaylistIDRoundTripsThroughJSON() throws {
        var index = LibraryIndex()
        let playlist = Playlist(id: PlaylistID(), name: "Ti1", kind: .xtream(host: "http://a.test"))
        index.add(playlist)
        index.activePlaylistID = playlist.id

        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(LibraryIndex.self, from: data)

        XCTAssertEqual(decoded.activePlaylistID, playlist.id)
        XCTAssertEqual(decoded.playlists.first?.name, "Ti1")
    }

    func testKeychainAccountsAreDistinctPerPlaylistAndFromTheLegacySlot() {
        let a = PlaylistID()
        let b = PlaylistID()
        XCTAssertNotEqual(a.keychainAccount, b.keychainAccount)
        XCTAssertNotEqual(a.keychainAccount, CredentialStore.defaultAccount)
        XCTAssertTrue(a.keychainAccount.hasPrefix("playlist-"))
    }

    func testEnabledPlaylistsExcludesDisabledOnesRegardlessOfProfile() {
        var index = LibraryIndex()
        var enabled = Playlist(id: PlaylistID(), name: "Ti1", kind: .xtream(host: "http://a.test"))
        enabled.order = 0
        var disabled = Playlist(id: PlaylistID(), name: "iTV4", kind: .xtream(host: "http://b.test"))
        disabled.order = 1
        disabled.isEnabled = false
        index.playlists = [enabled, disabled]

        XCTAssertEqual(index.enabledPlaylists.map(\.name), ["Ti1"])
    }
}
