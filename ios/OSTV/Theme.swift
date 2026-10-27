import SwiftUI

/// Brand tokens sampled from the OS TV mark, matching the Mac app's `Brand`.
enum Theme {
    static let surface = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x15 / 255)
    static let panel = Color(red: 0x16 / 255, green: 0x1A / 255, blue: 0x20 / 255)
    static let orange = Color(red: 0xFE / 255, green: 0x5D / 255, blue: 0x1E / 255)
    static let teal = Color(red: 0x04 / 255, green: 0x5E / 255, blue: 0x6E / 255)
    static let secondaryText = Color.white.opacity(0.62)
}
