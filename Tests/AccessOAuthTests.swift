import Foundation
import Testing

/// The Managed OAuth building blocks, against the documents a real Access app
/// returned: challenge parsing, metadata checks, PKCE and request shapes.
@Suite("Cloudflare Access: Managed OAuth pieces")
struct AccessOAuthTests {
    static let challenge = #"Bearer realm="OAuth", error="invalid_token", error_description="Missing or invalid access token", resource_metadata="https://transmission.example.com/.well-known/cloudflare-access-protected-resource/transmission/rpc""#

    static let resourceMetadata = #"""
    {"resource":"https://transmission.example.com/transmission/rpc","protected":true,"team_domain":"team.cloudflareaccess.com","authorization_servers":["https://team.cloudflareaccess.com"],"authentication_methods":[{"name":"cloudflared"},{"name":"oauth"}]}
    """#

    static let serverMetadata = #"""
    {"issuer":"https://team.cloudflareaccess.com","authorization_endpoint":"https://team.cloudflareaccess.com/cdn-cgi/access/oauth/authorization","token_endpoint":"https://team.cloudflareaccess.com/cdn-cgi/access/oauth/token","response_types_supported":["code"],"response_modes_supported":["query"],"grant_types_supported":["authorization_code","refresh_token"],"token_endpoint_auth_methods_supported":["client_secret_basic","client_secret_post","none"],"revocation_endpoint":"https://team.cloudflareaccess.com/cdn-cgi/access/oauth/revoke","registration_endpoint":"https://team.cloudflareaccess.com/cdn-cgi/access/oauth/registration","code_challenge_methods_supported":["S256"]}
    """#

    private func decode<T: Decodable>(_ json: String, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Challenge

    @Test func theBearerChallengeYieldsTheResourceMetadataURL() {
        #expect(AccessOAuth.resourceMetadataURL(fromWWWAuthenticate: Self.challenge)?.absoluteString
            == "https://transmission.example.com/.well-known/cloudflare-access-protected-resource/transmission/rpc")
    }

    @Test func otherChallengesYieldNothing() {
        #expect(AccessOAuth.resourceMetadataURL(fromWWWAuthenticate: #"Basic realm="Transmission""#) == nil)
        #expect(AccessOAuth.resourceMetadataURL(fromWWWAuthenticate: #"Bearer realm="OAuth""#) == nil)
        #expect(AccessOAuth.resourceMetadataURL(fromWWWAuthenticate: #"Bearer resource_metadata="http://x.example/m""#) == nil)
        #expect(AccessOAuth.resourceMetadataURL(fromWWWAuthenticate: nil) == nil)
    }

    @Test func challengeParametersHandleQuotesEscapesAndTokens() {
        let params = AccessOAuth.challengeParameters(#" realm="a \"b\", c", error=invalid_token, X="y""#)
        #expect(params["realm"] == #"a "b", c"#)
        #expect(params["error"] == "invalid_token")
        #expect(params["x"] == "y")
    }

    // MARK: - Metadata

    @Test func theAuthorizationServerMustBeACloudflareAccessTeamDomain() throws {
        let meta = try decode(Self.resourceMetadata, as: AccessOAuth.ResourceMetadata.self)
        #expect(meta.resource == "https://transmission.example.com/transmission/rpc")
        #expect(try AccessOAuth.authorizationServer(from: meta).absoluteString == "https://team.cloudflareaccess.com")
        for bad in [#"["https://login.evil.example"]"#, #"["http://team.cloudflareaccess.com"]"#, "[]"] {
            let m = try decode(#"{"resource":"r","authorization_servers":\#(bad)}"#, as: AccessOAuth.ResourceMetadata.self)
            #expect(throws: AccessError.self) { try AccessOAuth.authorizationServer(from: m) }
        }
    }

    @Test func serverMetadataURLFollowsRFC8414() {
        #expect(AccessOAuth.serverMetadataURL(for: URL(string: "https://team.cloudflareaccess.com")!).absoluteString
            == "https://team.cloudflareaccess.com/.well-known/oauth-authorization-server")
        #expect(AccessOAuth.serverMetadataURL(for: URL(string: "https://a.cloudflareaccess.com/t/")!).absoluteString
            == "https://a.cloudflareaccess.com/.well-known/oauth-authorization-server/t")
    }

    @Test func realServerMetadataPassesValidation() throws {
        let meta = try decode(Self.serverMetadata, as: AccessOAuth.ServerMetadata.self)
        try AccessOAuth.validate(meta, issuer: URL(string: "https://team.cloudflareaccess.com")!)
        #expect(meta.registrationEndpoint?.path == "/cdn-cgi/access/oauth/registration")
        #expect(meta.revocationEndpoint?.path == "/cdn-cgi/access/oauth/revoke")
    }

    @Test func serverMetadataProblemsAreRejected() throws {
        let issuer = URL(string: "https://team.cloudflareaccess.com")!
        let cases = [
            Self.serverMetadata.replacingOccurrences(of: #""issuer":"https://team.cloudflareaccess.com""#,
                                                     with: #""issuer":"https://other.cloudflareaccess.com""#),
            Self.serverMetadata.replacingOccurrences(of: "https://team.cloudflareaccess.com/cdn-cgi/access/oauth/token",
                                                     with: "https://evil.example/token"),
            Self.serverMetadata.replacingOccurrences(of: #"["S256"]"#, with: #"["plain"]"#),
            Self.serverMetadata.replacingOccurrences(of: #","none"]"#, with: "]"),
            Self.serverMetadata.replacingOccurrences(of: #""registration_endpoint":"https://team.cloudflareaccess.com/cdn-cgi/access/oauth/registration","#, with: ""),
        ]
        for json in cases {
            let meta = try decode(json, as: AccessOAuth.ServerMetadata.self)
            #expect(throws: AccessError.self) { try AccessOAuth.validate(meta, issuer: issuer) }
        }
    }

    // MARK: - PKCE

    @Test func pkceMatchesTheRFC7636Vector() {
        #expect(AccessOAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func freshPKCEStartsWithALetterOrDigit() {
        for _ in 0..<200 {
            let pkce = AccessOAuth.PKCE.make()
            #expect(pkce.verifier.count == 64)
            #expect(pkce.challenge.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true)
            #expect(pkce.challenge == AccessOAuth.PKCE.challenge(for: pkce.verifier))
        }
        #expect(AccessOAuth.randomState() != AccessOAuth.randomState())
    }

    // MARK: - Requests

    @Test func registrationRegistersAPublicLoopbackClient() throws {
        let request = AccessOAuth.registrationRequest(
            endpoint: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/oauth/registration")!,
            redirectURI: AccessOAuth.redirectURI(port: 53682), resource: "https://transmission.example.com/transmission/rpc")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.httpMethod == "POST")
        #expect(body["redirect_uris"] as? [String] == ["http://127.0.0.1:53682/callback"])
        #expect(body["token_endpoint_auth_method"] as? String == "none")
        #expect(body["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(body["resource"] as? String == "https://transmission.example.com/transmission/rpc")
    }

    @Test func authorizationURLCarriesPKCEStateAndResource() throws {
        let pkce = AccessOAuth.PKCE(verifier: "v", challenge: "abc+def")
        let url = AccessOAuth.authorizationURL(
            endpoint: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/oauth/authorization")!,
            clientID: "client-1", redirectURI: AccessOAuth.redirectURI(port: 53682), pkce: pkce,
            state: "st", resource: "https://transmission.example.com/transmission/rpc")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == [
            "client_id": "client-1", "redirect_uri": "http://127.0.0.1:53682/callback", "response_type": "code",
            "code_challenge": "abc+def", "code_challenge_method": "S256",
            "resource": "https://transmission.example.com/transmission/rpc", "state": "st",
        ])
        #expect(url.absoluteString.contains("abc%2Bdef"))
    }

    @Test func tokenRequestsAreFormEncoded() throws {
        let endpoint = URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/oauth/token")!
        let exchange = AccessOAuth.codeExchangeRequest(endpoint: endpoint, code: "c 1", clientID: "id",
                                                       redirectURI: AccessOAuth.redirectURI(port: 1), verifier: "v",
                                                       resource: "https://h/p")
        #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(String(decoding: try #require(exchange.httpBody), as: UTF8.self)
            == "grant_type=authorization_code&code=c+1&client_id=id&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback&code_verifier=v&resource=https%3A%2F%2Fh%2Fp")
        let refresh = AccessOAuth.refreshRequest(endpoint: endpoint, refreshToken: "oauth:r/t", clientID: "id", resource: "r")
        #expect(String(decoding: try #require(refresh.httpBody), as: UTF8.self)
            == "grant_type=refresh_token&refresh_token=oauth%3Ar%2Ft&client_id=id&resource=r")
        let revoke = AccessOAuth.revocationRequest(endpoint: endpoint, token: "t", hint: "refresh_token", clientID: "id")
        #expect(String(decoding: try #require(revoke.httpBody), as: UTF8.self) == "token=t&token_type_hint=refresh_token&client_id=id")
        #expect(AccessOAuth.formEncode([("k", "é")]) == "k=%C3%A9")
    }

    @Test func tokenResponsesAndErrorsDecode() throws {
        let token = try decode(#"{"access_token":"oauth:a","token_type":"bearer","expires_in":900,"refresh_token":"oauth:r","scope":""}"#,
                               as: AccessOAuth.TokenResponse.self)
        #expect(token.accessToken == "oauth:a" && token.refreshToken == "oauth:r" && token.expiresIn == 900)
        #expect(AccessOAuth.errorDescription(from: Data(#"{"error":"invalid_grant","error_description":"Code expired"}"#.utf8))
            == "Code expired (invalid_grant)")
        #expect(AccessOAuth.errorDescription(from: Data("<html>".utf8)) == nil)
    }
}
