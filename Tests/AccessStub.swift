import Foundation
import Synchronization

// A stubbed Cloudflare Access deployment with Managed OAuth, for sign-in tests:
// an app host that answers with a Bearer challenge and its resource metadata,
// a team domain serving authorization-server metadata, registration and token
// endpoints, a stub browser, and a stub loopback receiver (no real ports).

/// URLs the stub browser was asked to open.
final class OpenedURLs: Sendable {
    private let urls = Mutex<[URL]>([])
    func append(_ url: URL) { urls.withLock { $0.append(url) } }
    var all: [URL] { urls.withLock { $0 } }
}

/// Stands in for the 127.0.0.1 listener: the stub browser delivers the redirect.
final class StubReceiver: AuthorizationCallbackReceiver {
    let port: UInt16
    private struct State {
        var result: Result<[String: String], Error>?
        var waiter: CheckedContinuation<[String: String], Error>?
        var closed = false
    }
    private let state = Mutex(State())

    init(port: UInt16) { self.port = port }

    var isClosed: Bool { state.withLock { $0.closed } }

    func deliver(_ query: [String: String]) { finish(.success(query)) }

    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<[String: String], Error>? = state.withLock { s in
                    if let result = s.result { return result }
                    s.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            finish(.failure(AccessError.cancelled))
        }
    }

    func close() {
        state.withLock { $0.closed = true }
        finish(.failure(AccessError.cancelled))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let waiter: CheckedContinuation<[String: String], Error>? = state.withLock { s in
            guard s.result == nil else { return nil }
            s.result = result
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(with: result)
    }
}

/// Records which ports the sign-in asked the receiver factory for.
final class ReceiverFactory: Sendable {
    private let requested = Mutex<[UInt16?]>([])
    private let made = Mutex<[StubReceiver]>([])
    /// Ports that are "in use": asking for one fails.
    let busy: Set<UInt16>
    let freePort: UInt16

    init(busy: Set<UInt16> = [], freePort: UInt16 = 51_001) {
        self.busy = busy
        self.freePort = freePort
    }

    var requestedPorts: [UInt16?] { requested.withLock { $0 } }
    var receivers: [StubReceiver] { made.withLock { $0 } }

    func make(_ port: UInt16?) throws -> StubReceiver {
        requested.withLock { $0.append(port) }
        if let port, busy.contains(port) { throw AccessError.authorization("port \(port) in use") }
        let receiver = StubReceiver(port: port ?? freePort)
        made.withLock { $0.append(receiver) }
        return receiver
    }
}

enum AccessStub {
    static let tokenJSON = #"{"access_token":"oauth:access-1","token_type":"bearer","expires_in":900,"refresh_token":"oauth:refresh-1","scope":""}"#

    struct Deployment: Sendable {
        let appHost = StubURLProtocol.uniqueHost()
        let teamHost = "team-\(UUID().uuidString.lowercased()).cloudflareaccess.com"
        var appURL: URL { URL(string: "https://\(appHost)/transmission/rpc")! }
        var resource: String { "https://\(appHost)/transmission/rpc" }
        var issuer: URL { URL(string: "https://\(teamHost)")! }

        var discovery: AccessSignIn.Discovery {
            AccessSignIn.Discovery(resource: resource, issuer: issuer,
                                   authorizationEndpoint: URL(string: "https://\(teamHost)/cdn-cgi/access/oauth/authorization")!,
                                   tokenEndpoint: URL(string: "https://\(teamHost)/cdn-cgi/access/oauth/token")!,
                                   registrationEndpoint: URL(string: "https://\(teamHost)/cdn-cgi/access/oauth/registration")!,
                                   revocationEndpoint: URL(string: "https://\(teamHost)/cdn-cgi/access/oauth/revoke")!)
        }

        var challenge: StubURLProtocol.Reply {
            .init(status: 401, body: #"{"error":"invalid_token"}"#, headers: ["WWW-Authenticate":
                #"Bearer realm="OAuth", error="invalid_token", resource_metadata="https://\#(appHost)/.well-known/cloudflare-access-protected-resource/transmission/rpc""#])
        }

        var resourceMetadata: StubURLProtocol.Reply {
            .init(body: #"{"resource":"\#(resource)","protected":true,"authorization_servers":["https://\#(teamHost)"]}"#)
        }

        var serverMetadata: StubURLProtocol.Reply {
            let base = "https://\(teamHost)/cdn-cgi/access/oauth"
            return .init(body: #"{"issuer":"https://\#(teamHost)","authorization_endpoint":"\#(base)/authorization","token_endpoint":"\#(base)/token","registration_endpoint":"\#(base)/registration","revocation_endpoint":"\#(base)/revoke","token_endpoint_auth_methods_supported":["none"],"code_challenge_methods_supported":["S256"]}"#)
        }

        /// Queues the discovery replies; `team` follows the server metadata on the team host.
        func install(app: [StubURLProtocol.Reply]? = nil, team: [StubURLProtocol.Reply]) {
            StubURLProtocol.set(app ?? [challenge, resourceMetadata], for: appHost)
            StubURLProtocol.set([serverMetadata] + team, for: teamHost)
        }

        func session(accessToken: String? = "oauth:access-0", refreshToken: String? = "oauth:refresh-0",
                     expiresAt: Date?, port: UInt16 = 51_000, signedInAt: Date? = nil) -> AccessSession {
            AccessSession(discovery: discovery,
                          registration: AccessRegistration(clientID: "client-0", port: port, issuer: issuer, resource: resource),
                          accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, signedInAt: signedInAt)
        }
    }

    enum Browser: Sendable {
        /// Approves: redirects back with a code and the request's state.
        case approve
        case deny(String)
        case wrongState
        /// Never comes back.
        case never
    }

    /// An environment whose browser answers through the receivers `factory` made.
    static func environment(now: Date, browser: Browser = .approve, factory: ReceiverFactory = ReceiverFactory(),
                            opened: OpenedURLs = OpenedURLs(), callbackTimeout: TimeInterval = 5) -> AccessSignIn.Environment {
        AccessSignIn.Environment(
            session: URLSession(configuration: StubURLProtocol.configuration()),
            openBrowser: { url in
                opened.append(url)
                let items = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                guard let receiver = factory.receivers.last else { return true }
                switch browser {
                case .approve: receiver.deliver(["code": "code-1", "state": items["state"] ?? ""])
                case .deny(let error): receiver.deliver(["error": error, "error_description": "Denied", "state": items["state"] ?? ""])
                case .wrongState: receiver.deliver(["code": "code-1", "state": "forged"])
                case .never: break
                }
                return true
            },
            now: { now },
            callbackTimeout: callbackTimeout,
            makeReceiver: { try factory.make($0) })
    }

    /// The form fields of a recorded request body.
    static func form(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
        }
        var fields: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let key = kv.first { fields[key] = kv.count > 1 ? kv[1] : "" }
        }
        return fields
    }

    static func jsonBody(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
