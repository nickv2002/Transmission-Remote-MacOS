import Foundation
import Synchronization

/// A `URLProtocol` that answers from canned replies and records every request,
/// so client tests can check what goes on the wire without a daemon. State is
/// kept per host: give each test its own host (`StubURLProtocol.uniqueHost()`)
/// and suites can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = #"{"result":"success","arguments":{}}"#
        var headers: [String: String] = [:]
    }

    private struct HostState: Sendable {
        var replies: [Reply] = []
        var requests: [URLRequest] = []
    }

    private static let state = Mutex<[String: HostState]>([:])

    static func uniqueHost() -> String { "stub-\(UUID().uuidString.lowercased()).invalid" }

    /// Queue `replies` for `host`; a request with none left gets HTTP 599.
    static func set(_ replies: [Reply], for host: String) {
        state.withLock { $0[host] = HostState(replies: replies) }
    }

    static func requests(for host: String) -> [URLRequest] {
        state.withLock { $0[host]?.requests ?? [] }
    }

    /// A session configuration that routes every request through this stub.
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let reply = Self.state.withLock { all in
            var s = all[host] ?? HostState()
            s.requests.append(request)
            let reply = s.replies.isEmpty ? Reply(status: 599) : s.replies.removeFirst()
            all[host] = s
            return reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        // A 3xx with a Location goes through URLSession's redirect handling (and
        // so the task delegate), as a real server's would.
        if (300..<400).contains(reply.status), let location = reply.headers["Location"],
           let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
