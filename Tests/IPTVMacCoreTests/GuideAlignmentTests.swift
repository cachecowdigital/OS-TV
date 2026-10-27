import XCTest
@testable import IPTVMacCore

/// Guards the logic that decides whether a provider publishes its guide on another
/// clock. This is the difference between an empty grid and a working guide, and it is
/// pure arithmetic, so it gets tested rather than eyeballed.
///
/// The contract is deliberately modest, because the honest truth is that only a
/// *relative* shift is knowable: a guide can always be slid so that something is on
/// air. What is asserted here is that a guide already covering the reference instant is
/// left exactly alone, and that one which misses it is brought back over it by the
/// smallest correction that works.
final class GuideAlignmentTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14 17:46:40 UTC
    private var ids: [String] { (0..<6).map { "ch\($0)" } }

    /// A contiguous block of half-hour programmes, `durationHours` long, starting
    /// `offsetMinutes` away from `now` — a stand-in for a guide published on the
    /// wrong clock.
    private func block(channels: [String],
                       now: Date,
                       offsetMinutes: Int,
                       durationHours: Int = 6) -> [String: [XMLTVProgramme]] {
        var guide: [String: [XMLTVProgramme]] = [:]
        let slots = durationHours * 2
        for id in channels {
            guide[id] = (0..<slots).map { index in
                let start = now
                    .addingTimeInterval(TimeInterval(offsetMinutes * 60))
                    .addingTimeInterval(TimeInterval(index * 1800))
                return XMLTVProgramme(channelID: id, title: "Programme \(index)", detail: "",
                                      start: start, stop: start.addingTimeInterval(1800))
            }
        }
        return guide
    }

    func testCorrectlyPublishedGuideNeedsNoShift() {
        let guide = block(channels: ids, now: now, offsetMinutes: 0)
        XCTAssertEqual(GuideAlignment.coverage(programmes: guide, channelIDs: ids,
                                               offsetMinutes: 0, reference: now), 1.0, accuracy: 0.001)
        XCTAssertEqual(GuideAlignment.detectOffset(programmes: guide, channelIDs: ids, reference: now), 0)
    }

    func testGuideStampedHoursLateIsBroughtBackByTheSmallestShift() {
        let guide = block(channels: ids, now: now, offsetMinutes: 240)
        XCTAssertEqual(GuideAlignment.coverage(programmes: guide, channelIDs: ids,
                                               offsetMinutes: 0, reference: now), 0, accuracy: 0.001)

        let detected = GuideAlignment.detectOffset(programmes: guide, channelIDs: ids, reference: now)
        XCTAssertEqual(detected, -240,
                       "should prefer the smallest correction, not the extreme of the range")
        XCTAssertGreaterThan(GuideAlignment.coverage(programmes: guide, channelIDs: ids,
                                                     offsetMinutes: detected, reference: now), 0.9)
    }

    func testGuideStampedHoursEarlyIsBroughtForward() {
        let guide = block(channels: ids, now: now, offsetMinutes: -600)
        let detected = GuideAlignment.detectOffset(programmes: guide, channelIDs: ids, reference: now)
        // 255 rather than 240: the block ends exactly at the reference instant, and a
        // programme that ends at "now" is over, so the correction has to overshoot by
        // one search step before anything strictly contains it.
        XCTAssertEqual(detected, 255)
        XCTAssertGreaterThan(GuideAlignment.coverage(programmes: guide, channelIDs: ids,
                                                     offsetMinutes: detected, reference: now), 0.9)
    }

    /// Nothing inside the searchable range can rescue a guide this stale, so it must be
    /// left alone rather than dragged in front of the viewer.
    func testGuideFromDaysAgoIsLeftAlone() {
        let guide = block(channels: ids, now: now, offsetMinutes: -72 * 60)
        XCTAssertEqual(GuideAlignment.detectOffset(programmes: guide, channelIDs: ids, reference: now), 0)
    }

    func testNoProgrammesAtAllIsNotAnOffset() {
        XCTAssertEqual(GuideAlignment.detectOffset(programmes: [:], channelIDs: ["a", "b"], reference: now), 0)
        XCTAssertEqual(GuideAlignment.coverage(programmes: [:], channelIDs: [], offsetMinutes: 0,
                                               reference: now), 0, accuracy: 0.001)
    }

    /// Channels the guide knows nothing about must not count as failures, or a
    /// partially covered catalogue would look badly misaligned.
    func testChannelsMissingFromTheGuideAreIgnored() {
        let guide = block(channels: ["ch0", "ch1"], now: now, offsetMinutes: 0)
        XCTAssertEqual(GuideAlignment.coverage(programmes: guide, channelIDs: ids,
                                               offsetMinutes: 0, reference: now), 1.0, accuracy: 0.001)
    }
}
