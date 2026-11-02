import Foundation
import Synchronization
import Testing

/// Custom headers on the wire: configured headers are sent on every request
/// (including 409 retries), never replace the client's own headers, and extra
/// runtime sources stack after the configured ones.
@Suite("Custom request headers")
struct RequestHeadersTests {
    private static let ok = StubURLProtocol.Reply(body: #"{"result":"success","arguments":{"torrents":[]}}"#)

    private func server(_ host: String, headers: [CustomHeader], username: String? = "user") -> ServerConfig {
        ServerConfig(name: "Stub", host: host, port: 9091, useHTTPS: false, rpcPath: "/transmission/rpc",
                     username: username, password: username == nil ? nil : "pass", headers: headers)
    }

    private func client(_ server: ServerConfig, sources: [any RequestHeaderSource] = []) throws -> TransmissionClient {
        try TransmissionClient(server: server, configuration: StubURLProtocol.configuration(), headerSources: sources)
    }

    @Test func configuredHeadersAreSentInOrder() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([Self.ok], for: host)
        let c = try client(server(host, headers: [
            CustomHeader(name: "X-Client-Id", value: "id.access"),
            CustomHeader(name: " X-Client-Secret ", value: "s3cr3t"),
        ]))
        _ = try await c.fetchTorrents()

        let request = try #require(StubURLProtocol.requests(for: host).first)
        #expect(request.value(forHTTPHeaderField: "X-Client-Id") == "id.access")
        #expect(request.value(forHTTPHeaderField: "X-Client-Secret") == "s3cr3t")
    }

    @Test func headersAreResentOnSessionIdRetry() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([.init(status: 409, headers: ["X-Transmission-Session-Id": "abc"]), Self.ok], for: host)
        let c = try client(server(host, headers: [CustomHeader(name: "X-Token", value: "t")]))
        _ = try await c.fetchTorrents()

        let requests = StubURLProtocol.requests(for: host)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Token") == "t" })
        #expect(requests.last?.value(forHTTPHeaderField: "X-Transmission-Session-Id") == "abc")
    }

    /// A hand-edited preferences file can bypass Settings' validation; the
    /// client still never lets a custom header replace its own.
    @Test func reservedNamesNeverClobberBuiltInHeaders() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([.init(status: 409, headers: ["X-Transmission-Session-Id": "real-id"]), Self.ok], for: host)
        let c = try client(server(host, headers: [
            CustomHeader(name: "Content-Type", value: "text/plain"),
            CustomHeader(name: "authorization", value: "Bearer nope"),
            CustomHeader(name: "X-Transmission-Session-Id", value: "forged"),
            CustomHeader(name: "Host", value: "elsewhere.example"),
            CustomHeader(name: "X-Injected", value: "a\r\nX-Evil: 1"),
            CustomHeader(name: "X-Kept", value: "yes"),
        ]))
        _ = try await c.fetchTorrents()

        let requests = StubURLProtocol.requests(for: host)
        let first = try #require(requests.first), retry = try #require(requests.last)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
            #expect(request.value(forHTTPHeaderField: "Host") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Injected") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Kept") == "yes")
        }
        #expect(first.value(forHTTPHeaderField: "X-Transmission-Session-Id") == nil)
        #expect(retry.value(forHTTPHeaderField: "X-Transmission-Session-Id") == "real-id")
    }

    @Test func reservedAuthorizationIsDroppedEvenWithoutCredentials() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([Self.ok], for: host)
        let c = try client(server(host, headers: [CustomHeader(name: "Authorization", value: "Bearer nope")], username: nil))
        _ = try await c.fetchTorrents()
        #expect(StubURLProtocol.requests(for: host).first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func turnedOffHeadersAreNotSent() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([Self.ok], for: host)
        var s = server(host, headers: [CustomHeader(name: "X-Token", value: "t")])
        s.useCustomHeaders = false
        _ = try await client(s).fetchTorrents()
        #expect(StubURLProtocol.requests(for: host).first?.value(forHTTPHeaderField: "X-Token") == nil)
    }

    @Test func noConfiguredHeadersAddsNothing() async throws {
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([Self.ok], for: host)
        _ = try await client(server(host, headers: [])).fetchTorrents()
        let fields = try #require(StubURLProtocol.requests(for: host).first?.allHTTPHeaderFields)
        // Content-Length is URLSession's own, added for the body.
        #expect(Set(fields.keys.map { $0.lowercased() }) == ["content-type", "authorization", "content-length"])
    }

    /// A runtime source (e.g. a fetched token) stacks after the configured
    /// headers, wins on a repeated name, and is asked once per request.
    @Test func runtimeSourceStacksAfterConfiguredHeaders() async throws {
        final class CountingSource: RequestHeaderSource {
            let calls = Mutex(0)
            func headers() async throws -> [CustomHeader] {
                let n = calls.withLock { $0 += 1; return $0 }
                return [CustomHeader(name: "X-Token", value: "fetched-\(n)")]
            }
        }
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([.init(status: 409, headers: ["X-Transmission-Session-Id": "abc"]), Self.ok, Self.ok], for: host)
        let source = CountingSource()
        let c = try client(server(host, headers: [CustomHeader(name: "X-Token", value: "static"),
                                                  CustomHeader(name: "X-Static", value: "s")]),
                           sources: [source])
        _ = try await c.fetchTorrents()
        _ = try await c.fetchTorrents()

        let values = StubURLProtocol.requests(for: host).map { $0.value(forHTTPHeaderField: "X-Token") }
        #expect(values == ["fetched-1", "fetched-1", "fetched-2"])
        #expect(StubURLProtocol.requests(for: host).allSatisfy { $0.value(forHTTPHeaderField: "X-Static") == "s" })
        #expect(source.calls.withLock { $0 } == 2)
    }

    @Test func runtimeSourceErrorFailsTheRequestBeforeSending() async throws {
        struct Failing: RequestHeaderSource {
            struct Boom: Error {}
            func headers() async throws -> [CustomHeader] { throw Boom() }
        }
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.set([Self.ok], for: host)
        let c = try client(server(host, headers: []), sources: [Failing()])
        await #expect(throws: Failing.Boom.self) { _ = try await c.fetchTorrents() }
        #expect(StubURLProtocol.requests(for: host).isEmpty)
    }

    /// Failover probes build clients from host candidates, so those must carry the headers.
    @Test func hostCandidatesInheritHeaders() {
        let headers = [CustomHeader(name: "X-Token", value: "t")]
        let s = server("10.0.1.2, n5.local, https://proxy.example.test", headers: headers)
        #expect(s.connectionCandidates.count == 3)
        #expect(s.connectionCandidates.allSatisfy { $0.headers == headers })
    }
}
