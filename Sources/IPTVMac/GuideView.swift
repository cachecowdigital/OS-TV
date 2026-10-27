import SwiftUI
import AppKit
import IPTVMacCore

/// A TiviMate-style guide: a horizontal timeline per channel, a sticky channel
/// column, a sticky time ruler and a red "now" line. Programmes in the past are
/// catch-up; anything live or future tunes the live channel.
struct GuideView: View {
    @EnvironmentObject private var model: AppModel

    @State private var horizontalOffset: CGFloat = 0
    @State private var verticalOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 600
    @State private var loggedOffsetX: CGFloat = .infinity
    @State private var loggedOffsetY: CGFloat = .infinity

    private let channelColumnWidth: CGFloat = 190
    private let rowHeight: CGFloat = 44
    private let pointsPerMinute: CGFloat = 5
    private let maxChannels = 300

    private var windowStart: Date {
        // The reference point is now, moved by however far the timeline has been walked.
        // Everything else — the ruler, the row filtering, the now-line — is derived from
        // this, so the whole grid moves together.
        let now = Date().addingTimeInterval(TimeInterval(model.guideJumpMinutes * 60))
        let back = TimeInterval(-model.settings.data.guideMinutesBack * 60)
        let raw = now.addingTimeInterval(back)
        // round down to the half hour, as the spec asks
        let half = TimeInterval(30 * 60)
        return Date(timeIntervalSince1970: (raw.timeIntervalSince1970 / half).rounded(.down) * half)
    }

    private var windowEnd: Date {
        windowStart.addingTimeInterval(TimeInterval((model.settings.data.guideMinutesBack
            + model.settings.data.guideHoursAhead * 60) * 60))
    }

    private var totalMinutes: Int {
        Int(windowEnd.timeIntervalSince(windowStart) / 60)
    }

    /// Says where the timeline is, relative to now.
    private var timelineLabel: String {
        let minutes = model.guideJumpMinutes
        guard minutes != 0 else { return "Now" }
        let hours = abs(minutes) / 60, rest = abs(minutes) % 60
        let body = rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        return (minutes < 0 ? "−" : "+") + body
    }

    @ViewBuilder private var timelineControls: some View {
        HStack(spacing: 2) {
            Button { model.jumpGuide(byMinutes: -60) } label: { Image(systemName: "chevron.left.2") }
                .help("Back an hour")
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Button { model.jumpGuide(byMinutes: -30) } label: { Image(systemName: "chevron.left") }
                .help("Back half an hour  (⌘←)")
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Text(timelineLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.guideJumpMinutes == 0 ? Brand.textMuted : Brand.tealLifted)
                .frame(minWidth: 62)
            Button { model.jumpGuide(byMinutes: 30) } label: { Image(systemName: "chevron.right") }
                .help("Forward half an hour  (⌘→)")
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button { model.jumpGuide(byMinutes: 60) } label: { Image(systemName: "chevron.right.2") }
                .help("Forward an hour")
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            if model.guideJumpMinutes != 0 {
                Button("Now") { model.jumpGuideToNow() }
                    .help("Back to the current time  (⌘T)")
                    .keyboardShortcut("t", modifiers: [.command])
            }
        }
        .buttonStyle(.borderless)
    }

    private var gridWidth: CGFloat { CGFloat(totalMinutes) * pointsPerMinute }

    /// The programmes a row should draw.
    ///
    /// The model hands back *everything* it holds for a channel — days of listings, 149
    /// programmes in the sample that crashed. Drawing all of them for all 300 rows built
    /// roughly 45,000 views, and AttributeGraph aborts when its table cannot grow:
    /// `SIGABRT` in `AG::data::table::grow_region()`. That is what kept the grid off the
    /// screen — not the data, not the clock, and not the scroll geometry. Only what
    /// overlaps the window is worth building; the margin lets a block that starts just
    /// off the left edge still draw its tail.
    private func drawableProgrammes(for channel: Channel) -> [XMLTVProgramme] {
        let margin: TimeInterval = 2 * 3600
        let lower = windowStart.addingTimeInterval(-margin)
        let upper = windowEnd.addingTimeInterval(margin)
        return model.programmes(for: channel).filter { $0.stop > lower && $0.start < upper }
    }

    /// The rows that can actually be on screen.
    ///
    /// The sticky column is a plain stack, so drawing every row means one cell per
    /// channel that has guide data — 1,483 in the sample, 1,990 live — rebuilt on every
    /// scroll frame. Only the visible slice plus a small margin is worth building.
    /// Where the sticky layers get their scroll position from.
    ///
    /// SwiftUI cannot report a scroll offset at this deployment floor — see ScrollOffsetReader —
    /// and the GeometryReader-in-content preference that used to feed these values never delivered
    /// anything but zero on this build, which pinned the sticky column to the first rows and left
    /// the time ruler motionless while the grid scrolled underneath them.
    private func applyScrollOffset(_ point: CGPoint) {
        // Clamped at the source: the clip view's bounds origin can go negative mid-gesture, and a
        // negative horizontal offset slides the pinned column off the left edge.
        horizontalOffset = max(0, point.x)
        verticalOffset = max(0, point.y)
        // Same throttling as before, so the log stays readable and comparable.
        if abs(horizontalOffset - loggedOffsetX) > 40 || abs(verticalOffset - loggedOffsetY) > 40 {
            loggedOffsetX = horizontalOffset
            loggedOffsetY = verticalOffset
            model.writeGuideDiagnostics(
                "scroll offset h=\(Int(horizontalOffset)) v=\(Int(verticalOffset))"
                + " slice=\(onScreenRowRange.lowerBound)..<\(onScreenRowRange.upperBound)"
                + " inset=\(Int(sliceTopInset))")
        }
    }

    /// How far the first row of the slice sits above the viewport top, so a half-scrolled row
    /// still lines up with its own programme band. Viewport coordinates, like the slice itself.
    private var sliceTopInset: CGFloat {
        CGFloat(onScreenRowRange.lowerBound) * (rowHeight + 1) - verticalOffset
    }

    private var onScreenRowRange: Range<Int> {
        guard rowHeight > 0, !rows.isEmpty else { return 0..<0 }
        let stride = rowHeight + 1
        // Both ends have to be clamped against each other, not just against zero. The lower bound
        // used to be clamped alone, so a stale or not-yet-measured `verticalOffset` could push
        // `first` past the end of the rows and produce a range whose lower bound exceeded its
        // upper. SwiftUI draws nothing for an invalid range rather than complaining, which is a
        // silent failure: the sticky channel column came up blank while the programme grid, which
        // iterates every row, carried on drawing. That is the whole of "the channels aren't
        // showing" — the names and logos were never missing, the column was being asked for
        // nothing.
        let last = max(0, rows.count - 1)
        // The slice is the rows actually on screen, in viewport terms. It used to start three rows
        // above the visible one and be drawn at its *content* position, with the container
        // cancelling the scroll beneath it. That worked only while the scroll offset was always
        // zero — which made lowerBound zero too, landing the stack at y=26, inside the clip. The
        // moment the offset became real, the stack sat thousands of points below the top of a
        // viewport-height frame, `.clipped()` erased it, and the column went blank while the grid
        // scrolled on regardless. That is the misalignment: the names were never drawn over the
        // rows they belonged to.
        let first = min(max(0, Int(verticalOffset / stride)), last)
        let span = Int(viewportHeight / stride) + 2
        return first..<max(first + 1, min(rows.count, first + span))
    }

    private var rows: [Channel] {
        Array(model.guideVisibleChannels.prefix(maxChannels))
    }

    /// Logs the visible count on every appearance, count change and category change — and, only
    /// for a small selection (never "All Channels"), the full per-channel EPG match breakdown.
    /// This exists to pin down a reported case where the header says programmes are loaded but
    /// every row in a small category's grid draws empty: the dump shows directly whether each
    /// channel's own epg_channel_id matched anything, rather than requiring another guess.
    private func logGuideList() {
        let visible = model.guideVisibleChannels
        model.writeGuideDiagnostics("guide list: \(visible.count) channels for \(model.selectedCategoryID)")
        if visible.count <= 60 {
            model.writeGuideDiagnostics("guide epg match: " + model.epgMatchDebugDump(for: visible))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            guideHeader
            Divider().overlay(Brand.border)
                .onAppear { logGuideList() }
                .onChange(of: model.guideVisibleChannels.count) { _ in logGuideList() }
                .onChange(of: model.selectedCategoryID) { _ in logGuideList() }

            // A persistent full-width bar, not a floating corner box — matches a TiviMate
            // reference the owner photographed: thumbnail, title, time and synopsis for the
            // selected channel's current programme, always in the same place rather than
            // drifting over whatever the timeline happens to be showing underneath it.
            if model.settings.data.showGuidePreview, let channel = model.selectedChannel {
                GuideDetailBar(channel: channel)
                Divider().overlay(Brand.border)
            }

            if model.guideProgrammes.isEmpty {
                emptyState
            } else if !hasProgrammesInWindow {
                outOfWindowState
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        // A gutter the width of the sticky channel column. Without it the
                        // timeline starts underneath the column: the first half hour is
                        // invisible and the "now" line is never on screen, because the
                        // window deliberately begins half an hour back.
                        HStack(spacing: 0) {
                            Color.clear.frame(width: channelColumnWidth)
                            // Lazy: only the rows in view are built. Eagerly stacking
                            // all 300 is half of what aborted the view graph.
                            LazyVStack(spacing: 0) {
                                // Reserves the ruler's own height at the top of the scrollable
                                // content so the first row doesn't start underneath the pinned
                                // header — it must NOT draw the ruler itself. It used to: a second,
                                // fully-built copy of timeRuler sat here, visible only in the one
                                // frame before any scroll (and then only by luck, painted under the
                                // opaque stickyRuler overlay at v=0) and otherwise scrolling out of
                                // view with the first row — dead weight rebuilt on every layout for
                                // nothing anyone could ever see. stickyRuler is the only ruler drawn
                                // now, and it is the one actually fed by the verified scroll offset.
                                Color.clear.frame(width: gridWidth, height: 26)
                            ForEach(rows) { channel in
                                GuideRow(channel: channel,
                                         programmes: drawableProgrammes(for: channel),
                                         windowStart: windowStart,
                                         pointsPerMinute: pointsPerMinute,
                                         height: rowHeight,
                                         gridWidth: gridWidth,
                                         showProgress: model.settings.data.showGuideProgress)
                                    .frame(height: rowHeight)
                                Divider().overlay(Brand.border.opacity(0.5))
                            }
                        }
                            }
                            // Where the sticky layers get their offset. This was a GeometryReader
                            // preference — the canonical recipe — which published nothing but zero on
                            // this build. Worse, it stayed wired up as a second writer: its
                            // onPreferenceChange assigned that zero over the real offset on every
                            // layout, so the column was rebuilt for scroll position 0 while the grid
                            // moved on. Two writers for one value, one of them always wrong, is why
                            // the names did not travel with the rows. ScrollOffsetReader is now the
                            // only source.
                            .background(ScrollOffsetReader { point in
                                applyScrollOffset(point)
                            })
                    }
                }
                .onAppear {
                    let first = rows.first.map { model.programmes(for: $0).count } ?? -1
                    model.writeGuideDiagnostics(
                        "scroll view appeared: rows=\(rows.count) firstRowProgrammes=\(first) "
                        + "gridWidth=\(Int(gridWidth)) rowHeight=\(Int(rowHeight))")
                }
                .coordinateSpace(name: "guide")
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportHeight = geo.size.height }
                        // Logged on change, not on appear: the first reading is taken
                        // before final layout and reports a transient 100x54, which reads
                        // like a collapsed pane and sent me chasing the wrong fault once
                        // already.
                        .onChange(of: geo.size.height) { fresh in
                            viewportHeight = fresh
                            model.writeGuideDiagnostics(
                                "scroll viewport \(Int(geo.size.width))x\(Int(fresh)) "
                                + "gridWidth=\(Int(gridWidth))")
                        }
                })
                .overlay(alignment: .topLeading) { stickyRuler }
                // Between the ruler and the column, so the column covers it in the
                // channel gutter exactly as it covers the timeline.
                .overlay(alignment: .topLeading) { stickyNowLine }
                .overlay(alignment: .topLeading) { stickyChannelColumn }
                .allowsHitTesting(true)
            }

            // Credits footer: present whenever the guide is the active view (including its
            // empty and out-of-window states), absent everywhere else. Outside the ScrollView on
            // purpose, so it stays put instead of travelling with the grid.
            Divider().overlay(Brand.border)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                JabcorpCredit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Brand.surfaceRaised)
        }
        .onAppear {
            let branch = model.guideProgrammes.isEmpty
                ? "empty"
                : (hasProgrammesInWindow ? "grid" : "outOfWindow")
            model.writeGuideDiagnostics(
                "guide view appeared: branch=\(branch) rows=\(rows.count) "
                + "totalMinutes=\(totalMinutes) gridWidth=\(Int(gridWidth)) "
                + "window=\(GuideFormat.time(windowStart))-\(GuideFormat.time(windowEnd))")
        }
        // A banner appearing or clearing resizes the guide's own vertical space — it sits above
        // this view in a safeAreaInset — without the user touching the scroll view at all. That
        // resize is exactly the kind of layout change ScrollOffsetReader's resync was added to
        // catch; this line exists so a future blank-guide report can be checked against whether a
        // banner transition landed right before it, instead of guessing again.
        .onChange(of: model.banner) { new in
            model.writeGuideDiagnostics(
                "guide: banner \(new == nil ? "cleared" : "shown") h=\(Int(horizontalOffset)) "
                + "v=\(Int(verticalOffset)) vh=\(Int(viewportHeight)) "
                + "slice=\(onScreenRowRange.lowerBound)..<\(onScreenRowRange.upperBound)")
        }
    }

    private var guideHeader: some View {
        HStack(spacing: 10) {
            Text("TV Guide").font(.headline)
            if model.isLoadingGuide {
                Text(model.guideStatus).font(.caption).foregroundStyle(Brand.textMuted)
            } else {
                // Both populations get named. The old line paired the number of rows *shown* —
                // capped at 300 by maxChannels — with the number of programmes the guide holds
                // across every channel it matched, so it read as "300 channels carry 218,848
                // programmes" and then contradicted itself the moment the grid looked empty.
                // Both numbers from the same live population. `guideChannels` is rebuilt only when
                // the guide reloads, so a sidebar pick left it stale and the header could read
                // "showing 300 of 0 channels that have guide data" on a group with no EPG — the
                // same mismatched-population fault the empty state was fixed for.
                Text("showing \(rows.count) of \(model.guideVisibleChannels.count) channels in this selection"
                     + " • \(model.epgProgrammeCount) programmes loaded"
                     + (model.guideSpanText.isEmpty ? "" : " • \(model.guideSpanText)"))
                    .font(.caption).foregroundStyle(Brand.textMuted)
            }
            if !model.isLoadingGuide && !model.guideAlignmentNote.isEmpty {
                Text(model.guideAlignmentNote)
                    .font(.caption)
                    .foregroundStyle(Brand.tealLifted)
            }
            if !model.isLoadingGuide && model.settings.data.epgOffsetMinutes != 0 {
                Button("Reset shift") { model.clearGuideShift() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Undo the guide time shift")
            }
            timelineControls
            Spacer()
            if model.isLoadingGuide {
                ProgressView().controlSize(.small)
                Text("Loading guide…").font(.caption).foregroundStyle(Brand.textMuted)
            } else {
                Button { Task { await model.loadGuide(force: true) } } label: {
                    Label("Refresh Guide", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.surfaceRaised)
        .onAppear {
            model.writeGuideDiagnostics(
                "header appeared loading=\(model.isLoadingGuide) rows=\(rows.count) status=\(model.guideStatus)")
        }
        .onChange(of: model.isLoadingGuide) { fresh in
            model.writeGuideDiagnostics(
                "header: loading -> \(fresh) rows=\(rows.count) status=\(model.guideStatus)")
        }
        // Every move of the timeline is recorded with the window it produced, so the buttons
        // can be shown to work without watching the screen.
        .onChange(of: model.guideJumpMinutes) { minutes in
            model.writeGuideDiagnostics("timeline moved: \(minutes) min from now"
                + " -> window=\(GuideFormat.time(windowStart))-\(GuideFormat.time(windowEnd))")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock").font(.largeTitle).foregroundStyle(Brand.textMuted)
            Text(model.isLoadingGuide ? "Downloading the guide…" : "No guide data yet").font(.headline)
            Text(model.guideStatus).font(.callout).foregroundStyle(Brand.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            if model.isLoadingGuide {
                ProgressView().controlSize(.small)
            } else {
                Button("Load Guide") { Task { await model.loadGuide(force: true) } }
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.surface)
    }

    /// Whether anything at all would be drawn between the window's two edges. Checked against
    /// the full selection (`model.guideVisibleChannels`), not `rows` (capped at `maxChannels`
    /// for what's actually rendered) — a category over 300 channels must never be told "no
    /// guide data" just because the channels that actually carry it happened to sort past the
    /// cap. Capping what's drawn is a performance choice; it must never double as the answer to
    /// "does this selection have data at all."
    private var hasProgrammesInWindow: Bool {
        let from = windowStart
        let to = windowEnd
        for channel in model.guideVisibleChannels {
            if model.programmes(for: channel).contains(where: { $0.start < to && $0.stop > from }) {
                return true
            }
        }
        return false
    }

    /// How many programmes the FULL selection holds at all, ignoring the window — same reasoning
    /// as `hasProgrammesInWindow` above: this is "does the empty state apply," not "what's on
    /// screen," so it must not be limited by the display cap either.
    private var programmesHeldBySelection: Int {
        model.guideVisibleChannels.reduce(0) { $0 + model.programmes(for: $1).count }
    }

    /// True when this selection's channels carry no guide data at all, as opposed to a guide
    /// whose data simply sits outside the visible window.
    private var selectionHasNoGuide: Bool { programmesHeldBySelection == 0 }

    /// The guide loaded and matched channels but has nothing to draw where we are
    /// looking. Overwhelmingly that means the provider published it on another clock,
    /// so say exactly that and hand over the fix instead of showing a blank grid.
    private var outOfWindowState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectionHasNoGuide ? "list.bullet.rectangle" : "clock.badge.exclamationmark")
                .font(.largeTitle).foregroundStyle(Brand.orange)
            Text(selectionHasNoGuide
                 ? "These channels have no guide data"
                 : "Guide loaded, but nothing falls in this window")
                .font(.headline)

            if selectionHasNoGuide {
                // A different fault from an out-of-window guide, and it used to be described as
                // one: the sentence paired the whole guide's programme count with this
                // selection's channel count, so it read as a contradiction and blamed the
                // provider's clock. Round-the-clock and event groups genuinely have no EPG.
                Text("The guide holds \(model.epgProgrammeCount.formatted()) programmes"
                     + (model.guideSpanText.isEmpty ? "" : ", covering \(model.guideSpanText)")
                     + ", but none of the \(rows.count) channels in this selection are among the "
                     + "channels they cover.")
                    .font(.callout).foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
                Text("Round-the-clock and event channels are often published without any EPG. "
                     + "Pick another group, or All Channels.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
                HStack(spacing: 8) {
                    Button("All Channels") { model.selectedCategoryID = AppModel.allCategoryID }
                        .buttonStyle(.borderedProminent).tint(Brand.orange)
                    Button("EPG settings") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("The guide holds \(model.epgProgrammeCount.formatted()) programmes"
                     + (model.guideSpanText.isEmpty ? "" : ", covering \(model.guideSpanText)")
                     + " — and \(programmesHeldBySelection.formatted()) of them belong to the "
                     + "\(rows.count) channels here — but none fall between "
                     + "\(GuideFormat.time(windowStart)) and \(GuideFormat.time(windowEnd)).")
                    .font(.callout).foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
                Text("That normally means the provider stamps the guide on a different clock, "
                     + "or the guide is for another day.")
                    .font(.caption).foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
                HStack(spacing: 8) {
                    Button("Align to now") { model.alignGuideToNow() }
                        .buttonStyle(.borderedProminent).tint(Brand.orange)
                    Button("−1 h") { model.nudgeGuideShift(byMinutes: -60) }
                        .buttonStyle(.bordered)
                    Button("+1 h") { model.nudgeGuideShift(byMinutes: 60) }
                        .buttonStyle(.bordered)
                    Button("EPG settings") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Shift applied: \(model.settings.data.epgOffsetMinutes) min"
                     + (model.guideAlignmentNote.isEmpty ? "" : " • \(model.guideAlignmentNote)"))
                    .font(.caption2).foregroundStyle(Brand.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.surface)
    }

    private var timeRuler: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Brand.surfaceRaised)
            ForEach(Array(0...(totalMinutes / 30)), id: \.self) { step in
                let minutes = step * 30
                let x = CGFloat(minutes) * pointsPerMinute
                Text(GuideFormat.time(windowStart.addingTimeInterval(TimeInterval(minutes * 60))))
                    .font(.caption2)
                    .foregroundStyle(Brand.textMuted)
                    .offset(x: x + 4, y: 5)
                Rectangle().fill(Brand.border)
                    .frame(width: 1).offset(x: x)
            }
        }
        .frame(width: gridWidth, height: 26)
    }

    /// The "now" line belongs in the overlay layer with the rest of the sticky
    /// furniture, not inside the scrolling content.
    ///
    /// An earlier version of this comment blamed the unbounded height alone for the
    /// empty grid, and that was wrong: the grid was aborting inside AttributeGraph
    /// because it built a view for every programme of every row. This is still the
    /// right home for the line, for a smaller reason — out here its height is bounded
    /// by the scroll view, so it costs one rectangle rather than an unbounded child.
    private var stickyNowLine: some View {
        let x = channelColumnWidth - horizontalOffset
            + CGFloat(Date().timeIntervalSince(windowStart) / 60) * pointsPerMinute
        return Rectangle()
            // Hidden once the timeline is walked away from now: a red line pinned to an edge
            // would claim the present is somewhere it isn't.
            .fill(Date() >= windowStart && Date() <= windowEnd ? Color.red : Color.clear)
            .frame(width: 2)
            .offset(x: x, y: 0)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            // The only overlay that was still swallowing clicks: a 2pt-wide strip down the
            // busiest part of the guide, invisible as a target and dead when hit.
            .allowsHitTesting(false)
    }

    /// The channel column is drawn as an overlay offset by the scroll position, so
    /// it stays put while the timeline scrolls horizontally.
    private var stickyChannelColumn: some View {
        ZStack(alignment: .topLeading) {
            Brand.surface
            Rectangle().fill(Brand.surfaceRaised)
                .frame(width: channelColumnWidth, height: 26)
                .overlay(alignment: .leading) {
                    Text("Channel").font(.caption2).foregroundStyle(Brand.textMuted)
                        .padding(.leading, 8)
                }
                // The cell stack is a later sibling in this ZStack, so a partially-scrolled row
                // starting above the band painted straight over this label.
                .zIndex(1)
            VStack(spacing: 0) {
                ForEach(Array(rows[onScreenRowRange].enumerated()), id: \.element.id) { _, channel in
                    // The cell is the click target. It used to be inert: the whole column carried
                    // .allowsHitTesting(false) and the cell had no gesture at all, so clicking a
                    // channel name — the most natural thing to click in a guide, and the target the
                    // user described clicking — did nothing whatsoever. No highlight, no player
                    // change, no message, not even a log line.
                    Button {
                        model.play(channel)
                    } label: {
                        GuideChannelCell(channel: channel,
                                         isPlaying: model.selectedChannel?.id == channel.id,
                                         isFavourite: model.favourites.isFavourite(channel.streamID),
                                         showNumber: model.settings.data.showChannelNumbers,
                                         showLogo: model.settings.data.showLogos,
                                         showCatchUp: model.settings.data.showCatchUpBadge)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play \(channel.name)")
                    Divider().overlay(Brand.border.opacity(0.5))
                }
            }
            // The slice is drawn at the position those rows occupy in the list, so the
            // column stays aligned with the timeline it sits beside.
            .offset(y: 26 + sliceTopInset)
        }
        .frame(width: channelColumnWidth, alignment: .leading)
        .clipped()
        // No container offset. The slice above is already placed in viewport coordinates; this
        // overlay sits outside the scrolled content and does not move with it, so cancelling the
        // scroll here as well shifted the whole frame off the top of the pane.
        // The column rendered as an empty rectangle while every input looked correct, so it now
        // reports its own state. Guessing at this from the outside cost three wrong theories.
        .background(GeometryReader { geo in
            Color.clear.onAppear {
                model.writeGuideDiagnostics(
                    "channel column: w=\(Int(channelColumnWidth)) h=\(Int(geo.size.height))"
                    + " rows=\(rows.count) slice=\(onScreenRowRange.lowerBound)..<\(onScreenRowRange.upperBound)"
                    + " rowHeight=\(Int(rowHeight)) vh=\(Int(viewportHeight)) off=\(Int(verticalOffset))"
                    + " logos=\(model.settings.data.showLogos) numbers=\(model.settings.data.showChannelNumbers)")
            }
        })
    }

    /// Pinned time ruler. It is offset by the scroll position; the channel
    /// column is drawn over it afterwards, so the ruler's left overflow is
    /// hidden rather than covering the column header.
    private var stickyRuler: some View {
        timeRuler
            .offset(x: channelColumnWidth - horizontalOffset, y: 0)
            .frame(width: gridWidth, height: 26, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

/// Reports the enclosing scroll view's position, via the one mechanism that does not depend on
/// SwiftUI re-evaluating content geometry.
///
/// SwiftUI cannot *read* a scroll offset at this deployment floor: onScrollGeometryChange and
/// ScrollPosition are macOS 15+, scrollPosition(id:) and GeometryProxy.bounds(of:) are 14+, and
/// ScrollViewReader can only move a position, never report one. NSClipView has posted its
/// bounds-change notification for every scroll frame since 10.5. A flipped document view makes
/// clip bounds down-positive, the same sign convention the preference path used.
private struct ScrollOffsetReader: NSViewRepresentable {
    let onChange: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.attach(to: view)
        // Every SwiftUI re-layout re-pushes the clip view's CURRENT bounds, rather than trusting
        // the next NSClipView bounds-changed notification to eventually arrive. The two can
        // genuinely disagree: a resize that changes the clip view's visible SIZE without moving
        // its origin (the banner appearing/disappearing above the guide is exactly this — it
        // changes how much vertical space the ScrollView gets, not where it's scrolled to) is not
        // guaranteed to post that notification, which left the tracked offset describing a layout
        // that no longer existed while everything built from it — the sticky ruler and channel
        // column in particular — kept using the stale value.
        context.coordinator.resync()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator {
        var onChange: (CGPoint) -> Void
        private var observer: NSObjectProtocol?
        private weak var clipView: NSClipView?

        init(onChange: @escaping (CGPoint) -> Void) { self.onChange = onChange }

        /// Idempotent: called from both make and update, but only the first successful attach
        /// registers an observer.
        func attach(to view: NSView) {
            guard clipView == nil else { return }
            guard let scrollView = view.enclosingScrollView else {
                // Reported rather than assumed away: if this fires, the reader is not inside the
                // scroll view and the fallback is a different approach.
                NSLog("OSTV: ScrollOffsetReader found no enclosing NSScrollView")
                return
            }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clipView = clip
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                guard let self, let clip = self.clipView else { return }
                self.onChange(clip.bounds.origin)
            }
            // A fresh GuideView used to trust whatever position the clip view already had — the
            // comment here used to say that could be "state restoration" and leave it at that.
            // Confirmed live: it reproducibly is. Every relaunch landed the guide ~190 rows deep
            // into an 8,951-channel list, h=575 v=8556, before anything on screen had been
            // touched — the exact slice a banner showing up moments later (a dead resumed
            // channel) was then reported against. TiviMate doesn't open on row 190 of an
            // alphabetical list either way, so this resets to the top-left origin outright
            // instead of reporting a stale position computed against a view that may not even
            // share the current selection's row count.
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
            onChange(.zero)
        }

        /// Pushes the clip view's current bounds unconditionally. Called on every SwiftUI
        /// re-layout (`updateNSView`), not just once at attach time — see the comment at the call
        /// site for why that notification alone is not trustworthy.
        func resync() {
            guard let clipView else { return }
            onChange(clipView.bounds.origin)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

enum GuideFormat {
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
    static func range(_ from: Date, _ to: Date) -> String {
        "\(time(from)) – \(time(to))"
    }
}

struct GuideRow: View {
    let channel: Channel
    let programmes: [XMLTVProgramme]
    let windowStart: Date
    let pointsPerMinute: CGFloat
    let height: CGFloat
    let gridWidth: CGFloat
    let showProgress: Bool

    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Brand.surface)
            ForEach(programmes, id: \.self) { programme in
                block(for: programme)
            }
        }
        .frame(width: gridWidth, height: height, alignment: .topLeading)
        // A programme that begins before the window start gets a negative x (the window opens half
        // an hour back, so late-night blocks do), and nothing clipped them: they painted left out of
        // the grid and into the pinned channel column's band, showing up as faded programme text in
        // the place channel names belong. This row's frame begins at the gutter's right edge, so
        // clipping here cuts them exactly at that boundary.
        .clipped()
    }

    @ViewBuilder
    private func block(for programme: XMLTVProgramme) -> some View {
        let x = CGFloat(programme.start.timeIntervalSince(windowStart) / 60) * pointsPerMinute
        let w = max(CGFloat(programme.stop.timeIntervalSince(programme.start) / 60) * pointsPerMinute - 2, 18)
        let now = Date()
        let isPast = programme.stop < now
        let isLive = programme.start <= now && now < programme.stop
        // A past programme can only be played if the channel carries an archive. Drawn
        // like the others it invites a click that cannot work, so it is faded and
        // disabled instead, and the tooltip says why rather than leaving the user to
        // guess. A provider may simply not sell catch-up.
        let replayable = isPast && channel.hasArchive
        let unavailable = isPast && !channel.hasArchive

        Button {
            model.playProgramme(programme, on: channel)
        } label: {
            ProgrammeBlock(title: programme.title,
                           replayable: replayable,
                           isLive: isLive,
                           isPast: isPast,
                           progress: showProgress && isLive
                               ? now.timeIntervalSince(programme.start) / max(programme.stop.timeIntervalSince(programme.start), 1)
                               : nil)
                .opacity(unavailable ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .frame(width: w, height: height - 6, alignment: .leading)
        .offset(x: x, y: 3)
        .help("\(programme.title)\n\(GuideFormat.range(programme.start, programme.stop))"
              + (replayable
                 ? "\nClick to play from catch-up"
                 : unavailable
                   ? "\nCatch-up isn't available on this channel — the provider advertises no archive"
                   : "\nClick to watch live"))
        .padding(.leading, 0)
    }
}

struct ProgrammeBlock: View {
    let title: String
    /// Whether this channel can actually replay the programme. The rewind glyph is drawn
    /// only when it can: on every other past block it advertised a feature that isn't there.
    let replayable: Bool
    let isLive: Bool
    let isPast: Bool
    let progress: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isLive ? Brand.orange.opacity(0.22) : (isPast ? Brand.surfaceRaised : Brand.surfaceHover))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isLive ? Brand.orange.opacity(0.8) : Brand.border, lineWidth: 1)
                if let progress {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Brand.orange.opacity(0.30))
                        .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                }
                HStack(spacing: 4) {
                    if replayable {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9)).foregroundStyle(Brand.tealLifted)
                    }
                    Text(title)
                        .font(.system(size: 11, weight: isLive ? .semibold : .regular))
                        .foregroundStyle(isLive ? Brand.textPrimary : Brand.textMuted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

struct GuideChannelCell: View {
    let channel: Channel
    let isPlaying: Bool
    let isFavourite: Bool
    let showNumber: Bool
    let showLogo: Bool
    let showCatchUp: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showLogo {
                AsyncImage(url: channel.iconURL.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "tv").foregroundStyle(Brand.textMuted.opacity(0.5))
                }
                .frame(width: 26, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            VStack(alignment: .leading, spacing: 0) {
                if showNumber, channel.number > 0 {
                    Text("\(channel.number)").font(.system(size: 9)).foregroundStyle(Brand.textMuted)
                }
                Text(channel.name).font(.system(size: 11, weight: isPlaying ? .semibold : .regular))
                    .foregroundStyle(isPlaying ? Brand.orange : Brand.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            // The TiviMate reference photo shows a small history/clock glyph on every row that
            // carries an archive — a per-row signal, not just the badge the plain channel list
            // already had. Same hasArchive flag, same showCatchUpBadge setting, new spot.
            if showCatchUp && channel.hasArchive {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(Brand.tealLifted)
                    .help("\(channel.archiveDays)-day catch-up available")
            }
            if isFavourite {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Brand.orange)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPlaying ? Brand.orange.opacity(0.10) : Brand.surface)
    }
}


/// A persistent full-width bar above the grid — a TiviMate reference the owner photographed
/// shows the live thumbnail and the selected programme's details in exactly this shape,
/// always in the same place, rather than the floating corner box this replaces.
struct GuideDetailBar: View {
    @EnvironmentObject private var model: AppModel
    let channel: Channel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PlayerSurface(player: model.player)
                .frame(width: 192, height: 108)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.orange)
                    Text(channel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    if model.isCatchUp {
                        Text("CATCH-UP")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Brand.tealLifted.opacity(0.25), in: Capsule())
                            .foregroundStyle(Brand.tealLifted)
                    }
                }
                if let current = model.currentProgramme(for: channel) {
                    Text("\(GuideFormat.range(current.start, current.stop))  •  "
                         + "\(Int(current.stop.timeIntervalSince(current.start) / 60)) min")
                        .font(.system(size: 11)).foregroundStyle(Brand.textMuted)
                    Text(current.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.textPrimary).lineLimit(1)
                    if !current.detail.isEmpty {
                        Text(current.detail).font(.system(size: 11)).foregroundStyle(Brand.textMuted)
                            .lineLimit(2)
                    }
                } else {
                    Text("No programme data for this time").font(.system(size: 11))
                        .foregroundStyle(Brand.textMuted)
                }
            }
            Spacer(minLength: 4)
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.textMuted)
            .help("Full screen")

            Button {
                model.settings.data.showGuidePreview = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.textMuted)
            .help("Hide this bar (turn it back on in Settings / EPG)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surfaceRaised)
    }
}
