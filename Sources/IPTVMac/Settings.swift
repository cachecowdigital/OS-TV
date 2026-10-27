import Foundation
import Combine

public enum AppearanceChoice: String, Codable, CaseIterable, Sendable {
    case dark, light, system
    public var label: String { rawValue.capitalized }
}

public enum AccentChoice: String, Codable, CaseIterable, Sendable {
    case orange, teal
    public var label: String {
        switch self {
        case .orange: return "Amber"
        case .teal:   return "Teal"
        }
    }
}

public enum StreamFormat: String, Codable, CaseIterable, Sendable {
    case hls, ts
    public var label: String { self == .hls ? "HLS (.m3u8)" : "MPEG-TS (.ts)" }
}

public enum ChannelSort: String, Codable, CaseIterable, Sendable {
    case number, name
    public var label: String { self == .number ? "Channel number" : "Name" }
}

/// Everything the user can change, in one Codable value so a single didSet
/// persists the lot and @Observable tracks it as one stored property.
public struct SettingsData: Codable, Equatable, Sendable {
    // Appearance
    public var appearance: AppearanceChoice = .dark
    public var accent: AccentChoice = .orange
    public var compactRows: Bool = true
    public var showChannelNumbers: Bool = true
    public var showLogos: Bool = true
    public var showCatchUpBadge: Bool = true

    // Catch-up
    /// When a programme is already under way on a channel that carries an archive,
    /// start it from its beginning instead of joining it part-way. TiviMate offers the
    /// same switch; it only applies where the provider actually sells catch-up.
    public var startLiveFromBeginning: Bool = false

    // Playback
    public var preferredFormat: StreamFormat = .hls
    public var stopPreviousOnZap: Bool = true
    public var resumeLastChannel: Bool = true
    public var openInVLCPath: String = "/Applications/VLC.app"

    // Guide
    public var guideHoursAhead: Int = 6
    public var guideMinutesBack: Int = 30
    public var guideRefreshMinutes: Int = 30
    /// Providers sometimes publish the guide on a different clock, which shows up as a
    /// grid with nothing in it. When on, the app measures the shift and corrects it.
    public var autoAlignGuide: Bool = true
    public var epgOffsetMinutes: Int = 0
    public var showGuideProgress: Bool = true
    public var showGuidePreview: Bool = true

    // Channels
    public var sortOrder: ChannelSort = .number
    public var hideEmptyCategories: Bool = false
    public var hiddenCategoryIDs: [String] = []

    // Parental
    public var parentalEnabled: Bool = false
    public var parentalPIN: String = ""
    public var lockedCategoryKeywords: String = "adult, xxx, 18+, porn, erotic"
    public var lockSettings: Bool = false

    public init() {}
}

@MainActor
public final class AppSettings: ObservableObject {
    @Published public var data: SettingsData {
        didSet { persist() }
    }

    private static let key = "jabcorptv.settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = decoded
        } else {
            data = SettingsData()
        }
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: Self.key)
    }

    public func resetToDefaults() { data = SettingsData() }

    // MARK: Parental

    public var lockedKeywords: [String] {
        data.lockedCategoryKeywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    public func isLocked(category name: String) -> Bool {
        guard data.parentalEnabled else { return false }
        let lower = name.lowercased()
        return lockedKeywords.contains { lower.contains($0) }
    }

    // MARK: Export / import

    public func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? encoder.encode(data), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    public func importJSON(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: d) else { return false }
        data = decoded
        return true
    }
}
