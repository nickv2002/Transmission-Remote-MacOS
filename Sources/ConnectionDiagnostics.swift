import Foundation

/// Turns a failed connection attempt into a human-readable, field-targeted
/// message for the Settings "Test Connection" alert — so the user can tell
/// whether the host/port, the HTTPS toggle, the RPC path, or the credentials are
/// at fault. Pure (Foundation-only) so it can be unit-tested.
enum ConnectionDiagnostics {
    static func message(for error: Error, server: ServerConfig) -> String {
        let scheme = server.useHTTPS ? "HTTPS" : "HTTP"
        if let reason = error.accessSignInReason {
            return accessMessage(reason, server: server)
        }
        guard let te = error as? TransmissionError else {
            return error.localizedDescription
        }
        switch te {
        case .invalidURL:
            return "The host, port, or RPC path don’t form a valid URL. Check those fields."
        case .connectionFailed(let detail):
            return "Couldn’t reach \(server.host):\(server.port) over \(scheme). "
                + "Check the host, port, and the Use HTTPS setting (and that the daemon is running).\n\n\(detail)"
        case .authenticationFailed:
            return "Reached the server, but authentication was rejected (HTTP 401). "
                + "Check the username and password."
        case .httpError(404):
            return "Reached the server, but found no Transmission RPC at “\(server.rpcPath)” (HTTP 404). "
                + "Check the RPC Path."
        case .httpError(let code):
            return "Reached the server, but it returned HTTP \(code). "
                + "Check the RPC Path and that this is a Transmission daemon."
        case .rpcError(let message):
            return "Connected, but the server reported an error: \(message)."
        case .decodingFailed:
            return "Reached the server, but its response wasn’t valid Transmission RPC. "
                + "Check the RPC Path and HTTPS setting."
        case .accessSignInRequired(let reason):
            return accessMessage(reason, server: server)   // handled above; kept for exhaustiveness
        case .redirected(let status, let location):
            switch redirectKind(location, server: server) {
            case .toHTTPS:
                return "The server redirects plain HTTP to HTTPS (HTTP \(status)). Turn on Use HTTPS."
            case .otherHost(let host):
                return "The server redirected the request to \(host) instead of answering it (HTTP \(status)). "
                    + "This is usually a sign-in page from an access proxy in front of the daemon: "
                    + "add the headers the proxy expects under Custom Headers, or check that they’re still valid."
            case .sameHost(let path):
                return "The server redirected the request to “\(path)” instead of answering it (HTTP \(status)). "
                    + "Check the RPC Path and the Use HTTPS setting."
            case .unknown:
                return "The server answered with a redirect (HTTP \(status)) instead of answering the request. "
                    + "Check the host, RPC Path and Use HTTPS setting."
            }
        }
    }

    /// What to tell the user when Cloudflare Access wants a sign-in.
    static func accessMessage(_ reason: AccessSignInReason, server: ServerConfig) -> String {
        if reason == .managedOAuthOff {
            return "This server’s Cloudflare Access application doesn’t have Managed OAuth turned on, which signing in "
                + "from Transmission Remote needs. Turn it on (Access application ▸ Additional settings ▸ Managed OAuth, "
                + "allowing loopback clients), or add a service token’s headers under Custom Headers."
        }
        guard server.useCloudflareAccess else {
            return "This server is behind Cloudflare Access. Turn on “Sign in with Cloudflare Access” to sign in "
                + "in your browser, or add a service token’s headers under Custom Headers."
        }
        switch reason {
        case .expired:
            return "Your Cloudflare Access session for this server has ended. Click Sign In to sign in again in your browser."
        default:
            return "Cloudflare Access didn’t accept the request: you’re signed out, or your session ended. "
                + "Click Sign In to sign in in your browser."
        }
    }

    /// A terse reason for an Access sign-in, for a one-line-per-host list.
    static func shortAccess(_ reason: AccessSignInReason) -> String {
        switch reason {
        case .expired: return "Cloudflare Access session ended"
        case .signedOut: return "Cloudflare Access sign-in needed"
        case .managedOAuthOff: return "Cloudflare Access Managed OAuth is off"
        }
    }

    /// Where a refused redirect pointed, relative to the server it came from.
    enum RedirectKind: Equatable {
        /// Same host, now over HTTPS, while the server is set to plain HTTP.
        case toHTTPS
        /// Another host: typically an access proxy's sign-in page.
        case otherHost(String)
        /// Same host, another path (or scheme the server already uses).
        case sameHost(path: String)
        /// No usable Location header.
        case unknown
    }

    static func redirectKind(_ location: URL?, server: ServerConfig) -> RedirectKind {
        guard let location, let host = location.host else { return .unknown }
        guard host.caseInsensitiveCompare(server.host) == .orderedSame else { return .otherHost(host) }
        if location.scheme?.lowercased() == "https", !server.useHTTPS { return .toHTTPS }
        let path = location.path(percentEncoded: false)   // keeps a trailing slash, unlike `.path`
        return .sameHost(path: path.isEmpty ? "/" : path)
    }

    /// A terse reason for a refused redirect, for a one-line-per-host list.
    static func shortRedirect(status: Int, location: URL?, server: ServerConfig?) -> String {
        let kind = server.map { redirectKind(location, server: $0) }
            ?? location?.host.map(RedirectKind.otherHost) ?? .unknown
        switch kind {
        case .toHTTPS: return "redirects to HTTPS (turn on Use HTTPS)"
        case .otherHost(let host): return "redirected to \(host) (sign-in page? check Custom Headers)"
        case .sameHost(let path): return "redirected to \(path) (check the RPC Path)"
        case .unknown: return "redirected (HTTP \(status))"
        }
    }
}
