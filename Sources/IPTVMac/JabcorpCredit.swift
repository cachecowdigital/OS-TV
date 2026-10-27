import SwiftUI
import AppKit

/// Footer credit for the bottom of the guide: the Jabcorp lockup, clickable through to
/// jabcorp.ca.
///
/// A real row at the bottom of the guide's VStack, not an overlay on the grid. The grid already
/// carries three overlays (sticky ruler, now line, channel column) and every click bug in this
/// file's history came from one of them swallowing a region it did not own — a fourth overlay
/// parked in the timeline would be a fourth chance at that. A footer row can't take a click away
/// from a programme block because it isn't over one.
///
/// Deliberately quiet: 15pt tall, 62% opacity until hovered. This is a credit, not an ad.
struct JabcorpCredit: View {
    @State private var hovering = false

    static let destination = URL(string: "https://jabcorp.ca")!

    var body: some View {
        Button {
            NSWorkspace.shared.open(Self.destination)
        } label: {
            HStack(spacing: 7) {
                if let logo = Brand.jabcorpLogo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 15)
                } else {
                    // No asset in the bundle (bare `swift run`, or a build that skipped
                    // build_app.sh): say the same thing in words rather than showing a hole.
                    Text("JABCORP")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Brand.orange)
                }
                Text("jabcorp.ca")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Brand.textMuted)
            }
            // 0.75 idle, not 0.62: at 15pt the chip/brain's thin teal strokes turned to texture
            // when dimmed further. Still quiet, still clearly secondary to the guide.
            .opacity(hovering ? 1.0 : 0.75)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Jabcorp — opens jabcorp.ca")
        .accessibilityLabel("Jabcorp — opens jabcorp.ca")
    }
}
