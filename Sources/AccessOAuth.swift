import CryptoKit
import Foundation

// Cloudflare Access Managed OAuth, the documented sign-in for apps:
// https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/
//
// A request without a token gets `401` with
// `WWW-Authenticate: Bearer realm="OAuth", …, resource_metadata="<url>"` (RFC 9728).
// The resource metadata names the authorization server, whose RFC 8414 metadata
// gives the registration (RFC 7591), authorization (PKCE, RFC 7636) and token
// endpoints. Tokens are scoped with `resource` (RFC 8707). Foundation/CryptoKit
// only; unit-tested in AccessOAuthTests.

enum AccessOAuth {
    /// The `resource_metadata` URL from an Access Bearer challenge, or nil when
    /// the header isn't one (Transmission's own challenge is `Basic`).
    static func resourceMetadataURL(fromWWWAuthenticate header: String?) -> URL? {
        guard let header, header.lowercased().hasPrefix("bearer") else { return nil }
        let params = challengeParameters(String(header.dropFirst("bearer".count)))
        guard let raw = params["resource_metadata"], let url = URL(string: raw), url.scheme == "https" else {
            return nil
        }
        return url
    }

    /// `key="value"` / `key=token` pairs of an auth challenge, keys lowercased.
    static func challengeParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(text)
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "," })
            guard let eq = rest.firstIndex(of: "=") else { break }
            let key = rest[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: eq)...]
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                var end = rest.endIndex
                for i in rest.indices {
                    let c = rest[i]
                    if escaped { value.append(c); escaped = false; continue }
                    if c == "\\" { escaped = true; continue }
                    if c == "\"" { end = i; break }
                    value.append(c)
                }
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[rest.endIndex...]
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    // MARK: - Metadata

    /// RFC 9728 protected resource metadata.
    struct ResourceMetadata: Decodable, Sendable, Equatable {
        let resource: String
        let authorizationServers: [String]

        private enum CodingKeys: String, CodingKey {
            case resource
            case authorizationServers = "authorization_servers"
        }
    }

    /// RFC 8414 authorization server metadata (the fields this app uses).
    struct ServerMetadata: Decodable, Sendable, Equatable {
        let issuer: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
        let revocationEndpoint: URL?
        let codeChallengeMethodsSupported: [String]?
        let tokenEndpointAuthMethodsSupported: [String]?

        private enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case revocationEndpoint = "revocation_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
            case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        }
    }

    /// The authorization server to use: HTTPS on a Cloudflare Access team domain,
    /// so a hostile host can't send the sign-in anywhere else.
    static func authorizationServer(from metadata: ResourceMetadata) throws -> URL {
        for raw in metadata.authorizationServers {
            if let url = URL(string: raw), url.scheme == "https", let host = url.host,
               CloudflareAccess.authDomainHost(host) != nil {
                return url
            }
        }
        throw AccessError.discovery("the server didn’t name a Cloudflare Access sign-in server")
    }

    /// `<issuer>/.well-known/oauth-authorization-server` (RFC 8414).
    static func serverMetadataURL(for issuer: URL) -> URL {
        var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "/.well-known/oauth-authorization-server" + path
        components.query = nil
        return components.url!
    }

    /// Checks the server supports what this app needs: same issuer, HTTPS
    /// endpoints on the issuer's host, PKCE S256, public clients, and dynamic
    /// registration.
    static func validate(_ metadata: ServerMetadata, issuer: URL) throws {
        guard metadata.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw AccessError.discovery("the sign-in server identified itself differently")
        }
        var endpoints = [metadata.authorizationEndpoint, metadata.tokenEndpoint]
        endpoints += [metadata.registrationEndpoint, metadata.revocationEndpoint].compactMap { $0 }
        guard endpoints.allSatisfy({ $0.scheme == "https" && $0.host == issuer.host }) else {
            throw AccessError.discovery("the sign-in server’s endpoints aren’t on its own HTTPS host")
        }
        guard metadata.codeChallengeMethodsSupported?.contains("S256") == true else {
            throw AccessError.discovery("the sign-in server doesn’t support PKCE (S256)")
        }
        guard metadata.tokenEndpointAuthMethodsSupported?.contains("none") == true else {
            throw AccessError.discovery("the sign-in server doesn’t accept apps without a client secret")
        }
        guard metadata.registrationEndpoint != nil else {
            throw AccessError.discovery("the sign-in server doesn’t allow apps to register")
        }
    }

    // MARK: - PKCE

    struct PKCE: Sendable, Equatable {
        let verifier: String
        let challenge: String

        /// A fresh verifier and its S256 challenge. Access rejects challenges that
        /// start with "-" or "_", so those are drawn again.
        static func make() -> PKCE {
            while true {
                let verifier = base64URL(randomBytes(48))
                let challenge = Self.challenge(for: verifier)
                if let first = challenge.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) {
                    return PKCE(verifier: verifier, challenge: challenge)
                }
            }
        }

        static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    static func randomState() -> String { base64URL(randomBytes(16)) }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Requests

    /// The loopback redirect URI for `port` (RFC 8252 §7.3).
    static func redirectURI(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/callback")!
    }

    /// RFC 7591 dynamic registration of a public client.
    static func registrationRequest(endpoint: URL, redirectURI: URL, resource: String,
                                    clientName: String = "Transmission Remote") -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI.absoluteString],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "resource": resource,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    struct RegistrationResponse: Decodable, Sendable {
        let clientID: String
        private enum CodingKeys: String, CodingKey { case clientID = "client_id" }
    }

    static func authorizationURL(endpoint: URL, clientID: String, redirectURI: URL, pkce: PKCE,
                                 state: String, resource: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
        ]
        // URLComponents leaves "+" alone in queries; servers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func codeExchangeRequest(endpoint: URL, code: String, clientID: String, redirectURI: URL,
                                    verifier: String, resource: String) -> URLRequest {
        formRequest(endpoint, [
            ("grant_type", "authorization_code"), ("code", code), ("client_id", clientID),
            ("redirect_uri", redirectURI.absoluteString), ("code_verifier", verifier), ("resource", resource),
        ])
    }

    static func refreshRequest(endpoint: URL, refreshToken: String, clientID: String, resource: String) -> URLRequest {
        formRequest(endpoint, [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
            ("client_id", clientID), ("resource", resource),
        ])
    }

    /// RFC 7009 revocation of a token (best effort on sign-out).
    static func revocationRequest(endpoint: URL, token: String, hint: String, clientID: String) -> URLRequest {
        formRequest(endpoint, [("token", token), ("token_type_hint", hint), ("client_id", clientID)])
    }

    struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let tokenType: String?
        let expiresIn: Double?
        let refreshToken: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    /// An OAuth error body (`{"error": …, "error_description": …}`), if it is one.
    static func errorDescription(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String else { return nil }
        if let description = object["error_description"] as? String, !description.isEmpty {
            return "\(description) (\(error))"
        }
        return error
    }

    private static func formRequest(_ endpoint: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)
        return request
    }

    /// `application/x-www-form-urlencoded`: unreserved characters kept, space as "+".
    static func formEncode(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~ ")
        func encode(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: " ", with: "+")
        }
        return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
