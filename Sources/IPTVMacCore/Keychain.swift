import Foundation
import Security

/// The only place provider credentials live. Never written to disk, never logged.
public struct Credentials: Codable, Sendable, Hashable {
    public var server: String
    public var username: String
    public var password: String

    public init(server: String, username: String, password: String) {
        self.server = server
        self.username = username
        self.password = password
    }

    /// Safe to print. The password is never included.
    public var redacted: String { "\(username)@\(XtreamClient.normalizeServer(server))" }
}

public enum KeychainError: LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let s):
            let text = SecCopyErrorMessageString(s, nil) as String? ?? "unknown error"
            return "Keychain error \(s): \(text)"
        }
    }
}

/// Generic-password item in the login keychain.
///
/// ## Why this item is readable without an authorisation prompt
///
/// The login keychain authorises a reader by the reader's *code identity*. This app is
/// ad-hoc signed, and an ad-hoc identity is a hash of that particular binary — so every
/// rebuild is, to the keychain, a different application, and macOS answers each one by
/// demanding the login keychain password. Tested: signing with an identifier-based
/// designated requirement does **not** change this, and neither does "Always Allow" —
/// the next build prompts again. The only durable cures are a Developer ID signature or
/// an item that does not ask the question at all.
///
/// So the item is created with an access object that names a *nil* trusted application,
/// which is how the keychain is told "any application may read this without warning" —
/// the same thing `security add-generic-password -A` does. The trade-off is explicit:
/// any process running as this user can read this one credential without asking. It is
/// an IPTV subscription, the alternative is a password prompt that cannot be avoided,
/// and the item is still the user's own login keychain rather than a file. Reverting is
/// one line: pass `accessibleToAnyApplication: false`.
public enum CredentialStore {
    public static let service = "IPTVMac"
    /// The one subscription this app knew before it could hold more than one. Every call site
    /// that predates multi-subscription support calls these functions with no `account`
    /// argument, so it keeps reading and writing exactly this item — nothing about the single-
    /// subscription path changes. A second, third, ... subscription gets its own item under
    /// `Playlist.keychainAccount` instead, so they can never collide with this one or each other.
    public static let defaultAccount = "primary"

    /// An access object trusting any application. Returns nil if the system refuses,
    /// in which case the item is stored with the default per-application rules.
    private static func openAccess(label: String) -> SecAccess? {
        var anyApplication: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &anyApplication) == errSecSuccess,
              let trusted = anyApplication else { return nil }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, [trusted] as CFArray, &access) == errSecSuccess
        else { return nil }
        return access
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func save(_ credentials: Credentials, account: String = defaultAccount,
                            accessibleToAnyApplication: Bool = true) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        if accessibleToAnyApplication, let access = openAccess(label: service) {
            add[kSecAttrAccess as String] = access
        }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess, add[kSecAttrAccess as String] != nil {
            // The access object was refused. Store it anyway under the default rules —
            // a prompt after each build beats losing the saved credentials.
            add.removeValue(forKey: kSecAttrAccess as String)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func load(account: String = defaultAccount) -> Credentials? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func delete(account: String = defaultAccount) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
