import Foundation

// Per-server custom HTTP headers sent with every RPC request (for example the
// service-token headers an access proxy in front of the daemon expects).
// Foundation-only; unit-tested in CustomHeadersTests.

/// One custom header. Only the name is written to `preferences.json`; the value
/// is a secret kept in the Keychain (`HeaderSecretStore`) and filled in on load.
struct CustomHeader: Codable, Sendable, Equatable {
    var name: String
    var value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        value = ""   // never read from the file; PreferencesStore fills it from the Keychain
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
    }
}

/// Rules for custom header names and values, shared by Settings (which blocks
/// Apply on a problem) and the client (which skips reserved names even if a
/// hand-edited preferences file slips one past Settings).
enum HeaderValidation {
    enum Issue: Equatable, Sendable {
        case emptyName
        case invalidName
        /// URLSession owns these and may drop or replace them.
        case reservedBySystem
        /// The app sets these itself on every request.
        case reservedByApp
        /// `Authorization` comes from the Username and Password fields.
        case useCredentials
        case duplicate
        case valueHasLineBreak
    }

    /// Headers Apple documents as reserved for the URL loading system.
    static let systemReserved: Set<String> = [
        "authorization", "connection", "content-length", "host",
        "proxy-authenticate", "proxy-authorization", "www-authenticate",
    ]

    /// Headers `TransmissionClient` sets on every request.
    static let appReserved: Set<String> = ["content-type", "x-transmission-session-id"]

    /// RFC 9110 token characters, the only ones allowed in a field name.
    private static let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// True when the client must never send a header with this name.
    static func isReserved(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        return systemReserved.contains(lower) || appReserved.contains(lower)
    }

    /// The problem with the header at `index` in `headers`, or nil when it is fine.
    /// Only the second and later copies of a name count as duplicates.
    static func issue(at index: Int, in headers: [CustomHeader]) -> Issue? {
        let header = headers[index]
        let name = header.name.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        if name.isEmpty { return .emptyName }
        if name.unicodeScalars.contains(where: { !tokenCharacters.contains($0) }) { return .invalidName }
        if lower == "authorization" { return .useCredentials }
        if systemReserved.contains(lower) { return .reservedBySystem }
        if appReserved.contains(lower) { return .reservedByApp }
        if headers[..<index].contains(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == lower }) {
            return .duplicate
        }
        // Scalars, not Characters: "\r\n" is one Character equal to neither.
        if header.value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) { return .valueHasLineBreak }
        return nil
    }

    /// A message for `issue` on a header named `name`.
    static func message(for issue: Issue, name: String) -> String {
        let shown = name.trimmingCharacters(in: .whitespaces)
        switch issue {
        case .emptyName:
            return "Enter a name for each custom header."
        case .invalidName:
            return "“\(shown)” isn’t a valid header name. Use letters, digits and - only (no spaces or colons)."
        case .reservedBySystem:
            return "“\(shown)” is set by macOS and can’t be overridden."
        case .reservedByApp:
            return "“\(shown)” is set by Transmission Remote and can’t be overridden."
        case .useCredentials:
            return "Use the Username and Password fields instead of an Authorization header."
        case .duplicate:
            return "“\(shown)” is listed more than once."
        case .valueHasLineBreak:
            return "The value of “\(shown)” can’t contain line breaks."
        }
    }

    /// The first problem in `headers` as a message, or nil when all are valid.
    static func validationMessage(for headers: [CustomHeader]) -> String? {
        for index in headers.indices {
            if let issue = issue(at: index, in: headers) {
                return message(for: issue, name: headers[index].name)
            }
        }
        return nil
    }
}
