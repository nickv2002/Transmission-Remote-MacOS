import Foundation

// Cloudflare Access: the constants and errors shared by the Managed OAuth
// sign-in (AccessOAuth, AccessSignIn) and the token header source.
// Foundation-only; unit-tested in CloudflareAccessTests.

enum CloudflareAccess {
    /// Request header carrying the Access token. Access accepts its OAuth token
    /// here as well as in `Authorization: Bearer`, which leaves `Authorization`
    /// free for Transmission's own login.
    static let tokenHeader = "cf-access-token"
    /// A redirect whose Location path starts with this is Access sending the
    /// request to its browser login page, which it does when Managed OAuth is
    /// off for the application.
    static let loginPathPrefix = "/cdn-cgi/access/login"
    static let accessDomainSuffix = ".cloudflareaccess.com"

    /// The canonical (lowercased) team-domain host, or nil unless it is under
    /// `.cloudflareaccess.com`. Accepts a bare host or one with a port/path.
    static func authDomainHost(_ authDomain: String) -> String? {
        guard let host = URLComponents(string: "https://" + authDomain)?.host?.lowercased(),
              host.hasSuffix(accessDomainSuffix) else { return nil }
        return host
    }

    /// True when `location` is Access redirecting to its login page.
    static func isLoginRedirect(_ location: URL?) -> Bool {
        guard let location else { return false }
        return location.path(percentEncoded: true).hasPrefix(loginPathPrefix)
    }
}

enum AccessError: LocalizedError, Equatable {
    case notProtected
    /// The app host or a sign-in server couldn't be reached.
    case unreachable(String, String)
    /// OAuth discovery, registration, authorization or token exchange failed.
    case discovery(String)
    case registration(String)
    case authorization(String)
    case token(String)
    /// Access redirects to its login page instead of answering with a Bearer
    /// challenge: Managed OAuth is off for this application.
    case managedOAuthOff
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notProtected:
            return "This server isn’t protected by Cloudflare Access (no Access application answered for it)."
        case .unreachable(let host, let detail):
            return "Couldn’t reach \(host) to sign in: \(detail)"
        case .discovery(let detail):
            return "Couldn’t start signing in: \(detail)."
        case .registration(let detail):
            return "Cloudflare Access didn’t accept this app’s registration: \(detail)"
        case .authorization(let detail):
            return "The sign-in didn’t complete: \(detail)"
        case .token(let detail):
            return "Cloudflare Access didn’t issue a token: \(detail)"
        case .managedOAuthOff:
            return "This Cloudflare Access application doesn’t have Managed OAuth turned on. Turn it on "
                + "(Access application ▸ Additional settings ▸ Managed OAuth, allowing loopback clients), "
                + "then sign in again."
        case .timedOut:
            return "Sign-in timed out waiting for the browser. Try again."
        case .cancelled:
            return "Sign-in was cancelled."
        }
    }
}
