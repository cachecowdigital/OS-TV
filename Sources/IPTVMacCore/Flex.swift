import Foundation

/// A single value that a provider may send as Int, Double, Bool, String or null.
/// Xtream Codes servers are wildly inconsistent about this, so every scalar that
/// comes off the wire passes through here instead of a concrete Swift type.
public struct Flex: Decodable, Hashable, Sendable, CustomStringConvertible {
    public let stringValue: String
    public let intValue: Int
    public let doubleValue: Double

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            stringValue = ""; intValue = 0; doubleValue = 0
            return
        }
        if let i = try? c.decode(Int.self) {
            intValue = i; stringValue = String(i); doubleValue = Double(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            doubleValue = d; intValue = Int(d); stringValue = String(d)
            return
        }
        if let b = try? c.decode(Bool.self) {
            intValue = b ? 1 : 0; doubleValue = b ? 1 : 0; stringValue = b ? "true" : "false"
            return
        }
        let s = (try? c.decode(String.self)) ?? ""
        stringValue = s
        intValue = Int(s) ?? 0
        doubleValue = Double(s) ?? 0
    }

    public var boolValue: Bool {
        if !stringValue.isEmpty {
            switch stringValue.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return intValue != 0
            }
        }
        return intValue != 0
    }

    public var description: String { stringValue }
}

/// Lenient accessors used by every model's hand-written `init(from:)`.
/// A missing key, a wrong type, or an unexpected shape yields nil rather than
/// throwing — one odd field should never take down a 9,000-channel catalog.
extension KeyedDecodingContainer {
    public func str(_ key: Key) -> String? {
        guard let f = try? decodeIfPresent(Flex.self, forKey: key) else { return nil }
        return f.stringValue
    }

    public func int(_ key: Key) -> Int? {
        (try? decodeIfPresent(Flex.self, forKey: key))?.intValue
    }

    public func strArray(_ key: Key) -> [String] {
        ((try? decodeIfPresent([Flex].self, forKey: key)) ?? []).map(\.stringValue)
    }
}
