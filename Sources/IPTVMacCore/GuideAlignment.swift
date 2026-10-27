import Foundation

/// Works out whether a provider's guide is published on a different clock than ours.
///
/// This is a real and common provider bug: portals stamp XMLTV in UTC while meaning
/// their own local time (or vice versa), so every programme lands some whole number of
/// hours away from where it belongs. The grid then draws a window with nothing in it,
/// which looks like "no guide" when in fact the guide is fine and merely offset.
///
/// The test is simple and physical: at any instant, most channels should be showing
/// *something*. So we search shift candidates and pick the one that puts the most
/// channels on air right now.
public enum GuideAlignment {

    /// Share of the sampled channels that have a programme covering `reference`,
    /// once every programme is shifted by `offsetMinutes`.
    public static func coverage(programmes: [String: [XMLTVProgramme]],
                                channelIDs: [String],
                                offsetMinutes: Int,
                                reference: Date) -> Double {
        guard !channelIDs.isEmpty else { return 0 }
        let shift = TimeInterval(offsetMinutes * 60)
        var judgeable = 0
        var onAir = 0
        for id in channelIDs {
            guard let list = programmes[id], !list.isEmpty else { continue }
            judgeable += 1
            // Half-open on purpose: a programme that ends exactly at the reference
            // instant is over, not still running.
            let hit = list.contains { programme in
                programme.start.addingTimeInterval(shift) <= reference
                    && reference < programme.stop.addingTimeInterval(shift)
            }
            if hit { onAir += 1 }
        }
        // Only channels the guide actually covers can say anything about alignment.
        guard judgeable > 0 else { return 0 }
        return Double(onAir) / Double(judgeable)
    }

    /// How many channels to sample. The answer is statistical, so a few hundred
    /// channels is plenty and keeps this off the critical path for a 9,000-channel
    /// catalogue.
    public static let sampleSize = 200

    /// Below this many channels the measurement is not evidence, so no shift is
    /// offered however convincing the arithmetic looks.
    public static let minimumJudgeableChannels = 5

    /// The offset, in minutes, that best aligns the guide with `reference`.
    ///
    /// Returns 0 — meaning "do not touch it" — unless a shift is *clearly* better
    /// than no shift, so a sparse or genuinely empty guide is never yanked around on
    /// a hunch. The confidence bar is deliberately blunt: at least half the sampled
    /// channels on air, and a quarter more of them than the unshifted data manages.
    public static func detectOffset(programmes: [String: [XMLTVProgramme]],
                                    channelIDs: [String],
                                    reference: Date = Date(),
                                    stepMinutes: Int = 15,
                                    maxHours: Int = 12,
                                    minimumCoverage: Double = 0.5,
                                    minimumImprovement: Double = 0.25) -> Int {
        let sample = Array(channelIDs.filter { !(programmes[$0] ?? []).isEmpty }.prefix(sampleSize))
        guard sample.count >= minimumJudgeableChannels else { return 0 }

        let baseline = coverage(programmes: programmes, channelIDs: sample,
                               offsetMinutes: 0, reference: reference)

        // Find the best coverage first, then choose the smallest shift that achieves
        // it. A guide spanning several days covers "now" under a whole range of
        // shifts, so without this the answer would be an arbitrary corner of that
        // range — and the smaller correction is both likelier and easier to undo.
        var bestCoverage = baseline
        var minutes = -maxHours * 60
        while minutes <= maxHours * 60 {
            let value = coverage(programmes: programmes, channelIDs: sample,
                                 offsetMinutes: minutes, reference: reference)
            if value > bestCoverage { bestCoverage = value }
            minutes += stepMinutes
        }

        var bestOffset = 0
        var smallest = Int.max
        minutes = -maxHours * 60
        while minutes <= maxHours * 60 {
            let value = coverage(programmes: programmes, channelIDs: sample,
                                 offsetMinutes: minutes, reference: reference)
            if value >= bestCoverage - 0.0001, abs(minutes) < smallest {
                smallest = abs(minutes)
                bestOffset = minutes
            }
            minutes += stepMinutes
        }

        guard bestOffset != 0,
              bestCoverage >= minimumCoverage,
              bestCoverage - baseline >= minimumImprovement
        else { return 0 }

        return bestOffset
    }
}
