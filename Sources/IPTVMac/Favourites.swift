import Foundation
import Combine

public struct FavouritesData: Codable, Equatable, Sendable {
    public var streamIDs: [Int] = []
    public var recentStreamIDs: [Int] = []
    public var groups: [String: [Int]] = [:]
    public init() {}
}

@MainActor
public final class FavouritesStore: ObservableObject {
    @Published public var data: FavouritesData {
        didSet { persist() }
    }

    private static let key = "jabcorptv.favourites.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(FavouritesData.self, from: raw) {
            data = decoded
        } else {
            data = FavouritesData()
        }
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: Self.key)
    }

    public func isFavourite(_ id: Int) -> Bool { data.streamIDs.contains(id) }

    public func toggle(_ id: Int) {
        if let i = data.streamIDs.firstIndex(of: id) { data.streamIDs.remove(at: i) }
        else { data.streamIDs.append(id) }
    }

    public func noteWatched(_ id: Int) {
        var recents = data.recentStreamIDs.filter { $0 != id }
        recents.insert(id, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        data.recentStreamIDs = recents
    }

    public func addGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, data.groups[trimmed] == nil else { return }
        data.groups[trimmed] = []
    }

    public func removeGroup(_ name: String) { data.groups[name] = nil }

    public func toggle(_ id: Int, in group: String) {
        var members = data.groups[group] ?? []
        if let i = members.firstIndex(of: id) { members.remove(at: i) } else { members.append(id) }
        data.groups[group] = members
    }
}
