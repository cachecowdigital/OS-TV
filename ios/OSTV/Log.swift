import Foundation

/// A tiny append-only diagnostic log, written to the app's Documents directory.
///
/// The Mac app's whole debugging method is "read what the app actually did", and the same
/// thing is needed on a phone where there is no terminal. Everything the iOS app decides —
/// login, catalogue size, stream URL chosen, player state changes — lands here first.
enum Log {
    private static let queue = DispatchQueue(label: "ca.benyik.ostv.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ostv.log")
    }

    static func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
        // Also to stderr so `simctl launch --console` and Console.app show it live.
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }

    /// The last `count` lines, for the in-app diagnostics screen.
    static func tail(_ count: Int = 60) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "(no log yet)" }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
