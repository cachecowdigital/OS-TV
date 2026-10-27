import SwiftUI
import AppKit

/// App palette. Colour values are sampled from the app's own master logo (97%+ of the ink
/// is exactly orange #FE5D1E and teal #045E6E); the dark surfaces follow the
/// the app's own design tokens.
public enum Brand {
    public static let orange     = Color(red: 0xFE / 255, green: 0x5D / 255, blue: 0x1E / 255)
    public static let teal       = Color(red: 0x04 / 255, green: 0x5E / 255, blue: 0x6E / 255)
    /// Brand teal lifted for legibility on dark surfaces (same hue, raised lightness).
    public static let tealLifted = Color(red: 0x30 / 255, green: 0x9F / 255, blue: 0xB5 / 255)

    public static let surface       = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x15 / 255)
    public static let surfaceRaised = Color(red: 0x17 / 255, green: 0x1A / 255, blue: 0x1F / 255)
    public static let surfaceHover  = Color(red: 0x1F / 255, green: 0x23 / 255, blue: 0x29 / 255)
    public static let border        = Color(red: 0x27 / 255, green: 0x2B / 255, blue: 0x31 / 255)
    public static let textPrimary   = Color(red: 0xD0 / 255, green: 0xD8 / 255, blue: 0xE0 / 255)
    public static let textMuted     = Color(red: 0x80 / 255, green: 0x91 / 255, blue: 0xA2 / 255)

    public static let appName = "OS TV"

    /// Assets are copied next to the binary by build_app.sh; when running the bare
    /// SwiftPM binary there is no bundle, so fall back to the executable directory.
    public static func image(named name: String, extension ext: String) -> NSImage? {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { candidates.append(u) }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("\(name).\(ext)"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Sources/IPTVMac/Resources/\(name).\(ext)"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }

    public static var lockup: NSImage? { image(named: "BrandLockup", extension: "png") }
    public static var mark: NSImage? { image(named: "BrandMark", extension: "png") }
    /// The Jabcorp company lockup, prepared for a dark surface (the wordmark keeps its brand
    /// orange; the chip/brain icon was lifted to `tealLifted` so it survives on #0E1115).
    public static var jabcorpLogo: NSImage? { image(named: "JabcorpLogo", extension: "png") }
}

/// The lockup panel, sized to a given width, for the login screen and About.
public struct BrandLockup: View {
    public var width: CGFloat
    public init(width: CGFloat = 340) { self.width = width }

    public var body: some View {
        if let img = Brand.lockup {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .accessibilityLabel("OS TV")
        } else {
            Text(Brand.appName)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Brand.orange)
        }
    }
}

/// Small brand mark for the sidebar/toolbar strip.
public struct BrandMark: View {
    public var size: CGFloat
    public init(size: CGFloat = 22) { self.size = size }

    public var body: some View {
        if let img = Brand.image(named: "BrandMark", extension: "png") {
            Image(nsImage: img).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Brand.orange)
                .frame(width: size, height: size)
        }
    }
}
