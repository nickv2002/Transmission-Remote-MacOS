import Foundation
import Synchronization
import Testing

private final class OptionsURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = #"{"result":"success","arguments":{}}"#
        var headers: [String: String] = [:]
    }
    private struct State: Sendable {
        var replies: [Reply] = []
        var requests: [URLRequest] = []
    }
    private static let state = Mutex(State())
    static func reset(_ replies: [Reply]) { state.withLock { $0 = State(replies: replies) } }
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { state in
            state.requests.append(request)
            return state.replies.isEmpty ? Reply(status: 599) : state.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Server Options RPC transport", .serialized)
struct ServerOptionsRPCTests {
    private func client(_ replies: [OptionsURLProtocol.Reply]) throws -> TransmissionClient {
        OptionsURLProtocol.reset(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OptionsURLProtocol.self]
        return try TransmissionClient(server: ServerConfig(name: "Protocol stub", host: "fixture.invalid", port: 19091,
                                      useHTTPS: false, rpcPath: "/transmission/rpc", username: "test", password: "test"),
                                      configuration: config)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let bytes = request.httpBody { data = bytes }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var result = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            data = result
        } else { throw ServerOptionsError(message: "No request body") }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func loadUsesSessionGetAndDecodesLegacyWireKeys() async throws {
        let c = try client([.init(body: #"{"result":"success","arguments":{"version":"4.0.6","seedRatioLimited":true,"seedRatioLimit":2.5,"download-dir":"/data","speed-limit-down":0}}"#)])
        let options = try await c.fetchServerOptions()
        #expect(options.values[.ratioEnabled] == .bool(true))
        #expect(options.values[.ratio] == .decimal(2.5))
        #expect(options.values[.downloadDir] == .string("/data"))
        #expect(options.values[.down] == .int(0))
        #expect(options.values[.up] == nil)
        let request = try #require(OptionsURLProtocol.requests.first)
        #expect(try body(request)["method"] as? String == "session-get")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dGVzdDp0ZXN0")
    }

    @Test func saveSendsOnlyTypedEditsAndDoesNotToggleTurtleMode() async throws {
        let c = try client([.init()])
        try await c.setServerOptions([.down: .int(250), .ratio: .decimal(2.5), .incompleteEnabled: .bool(false)])
        let payload = try body(#require(OptionsURLProtocol.requests.first))
        #expect(payload["method"] as? String == "session-set")
        let args = try #require(payload["arguments"] as? [String: Any])
        #expect(Set(args.keys) == ["speed-limit-down", "seedRatioLimit", "incomplete-dir-enabled"])
        #expect(args["speed-limit-down"] as? Int == 250)
        #expect(args["seedRatioLimit"] as? Double == 2.5)
        #expect(args["incomplete-dir-enabled"] as? Bool == false)
        #expect(args["alt-speed-enabled"] == nil)
    }

    @Test func emptyPatchSendsNothing() async throws {
        let c = try client([])
        try await c.setServerOptions([:])
        #expect(OptionsURLProtocol.requests.isEmpty)
    }

    @Test func csrfHandshakeReplaysWithServerToken() async throws {
        let c = try client([.init(status: 409, headers: ["X-Transmission-Session-Id": "fixture-token"]), .init()])
        try await c.setServerOptions([.up: .int(50)])
        #expect(OptionsURLProtocol.requests.count == 2)
        #expect(OptionsURLProtocol.requests.last?.value(forHTTPHeaderField: "X-Transmission-Session-Id") == "fixture-token")
        let args = try body(#require(OptionsURLProtocol.requests.last))["arguments"] as? [String: Int]
        #expect(args == ["speed-limit-up": 50])
    }

    @Test func repeatedCsrfFailureIsBounded() async throws {
        let c = try client(Array(repeating: .init(status: 409, headers: ["X-Transmission-Session-Id": "rotating"]), count: 8))
        await #expect(throws: TransmissionError.self) { try await c.setServerOptions([.up: .int(50)]) }
        #expect(OptionsURLProtocol.requests.count == 4)
    }

    @Test(arguments: [401, 403, 500])
    func httpFailuresAreSurfaced(_ status: Int) async throws {
        let c = try client([.init(status: status)])
        await #expect(throws: TransmissionError.self) { try await c.fetchServerOptions() }
    }

    @Test(arguments: [#"{"result":"invalid argument"}"#, #"{"result":"success"}"#, "not-json"])
    func rpcAndMalformedResponsesAreSurfaced(_ body: String) async throws {
        let c = try client([.init(body: body)])
        await #expect(throws: TransmissionError.self) { try await c.fetchServerOptions() }
    }

    @Test(arguments: [true, false])
    func portTestDecodesOpenAndClosed(_ open: Bool) async throws {
        let c = try client([.init(body: "{\"result\":\"success\",\"arguments\":{\"port-is-open\":\(open)}}")])
        #expect(try await c.testPeerPort() == open)
        #expect(try body(#require(OptionsURLProtocol.requests.first))["method"] as? String == "port-test")
    }

    @Test func portTestDoesNotTreatMissingResultAsClosed() async throws {
        let c = try client([.init()])
        await #expect(throws: TransmissionError.self) { try await c.testPeerPort() }
    }
    @Test func modernFieldsUseActualCompatibilityWireNamesAndArrays() async throws {
        let c = try client([.init()])
        try await c.setServerOptions([.transports: .strings(["tcp", "utp"]), .sequential: .bool(true), .defaultTrackers: .string("udp://t.invalid:80/a\n\nhttps://t.invalid/a"), .bruteForceThreshold: .int(123), .doneScript: .string("/scripts/done")])
        let request = try #require(OptionsURLProtocol.requests.first)
        let args = try #require(body(request)["arguments"] as? [String: Any])
        #expect(args["preferred_transports"] as? [String] == ["tcp", "utp"])
        #expect(args["sequential_download"] as? Bool == true)
        #expect(args["default-trackers"] as? String == "udp://t.invalid:80/a\n\nhttps://t.invalid/a")
        #expect(args["anti-brute-force-threshold"] as? Int == 123)
        #expect(args["script-torrent-done-filename"] as? String == "/scripts/done")
        #expect(args["utp-enabled"] == nil)
    }

    @Test(arguments: PeerPortProtocol.allCases)
    func portProtocolIsSentExplicitlyAndReported(_ choice: PeerPortProtocol) async throws {
        let c = try client([.init(body: #"{"result":"success","arguments":{"port-is-open":false,"ip_protocol":"ipv6"}}"#)])
        if choice == .ipv4 {
            await #expect(throws: TransmissionError.self) { try await c.testPeerPort(protocol: choice) }
        } else {
            let result = try await c.testPeerPort(protocol: choice)
            #expect(!result.isOpen && result.ipProtocol == "ipv6")
        }
        let request = try #require(OptionsURLProtocol.requests.first)
        let args = try #require(body(request)["arguments"] as? [String: String])
        #expect(args == (choice == .automatic ? [:] : ["ip_protocol": choice.rawValue]))
    }

    @Test func groupReadAndSparseSaveUseCompatibilityKeys() async throws {
        let c = try client([.init(body: #"{"result":"success","arguments":{"group":[{"name":"Slow","honorsSessionLimits":true,"speed-limit-down-enabled":true,"speed-limit-down":123,"speed-limit-up-enabled":false,"speed-limit-up":25}]}}"#), .init()])
        let groups = try await c.fetchBandwidthGroups()
        #expect(groups == [BandwidthGroup(name: "Slow", honorsSessionLimits: true, downEnabled: true, down: 123, upEnabled: false, up: 25)])
        try await c.setBandwidthGroup(name: "Slow", changes: [.honors: .bool(false), .up: .int(10)])
        #expect(try body(OptionsURLProtocol.requests[0])["method"] as? String == "group-get")
        let payload = try body(OptionsURLProtocol.requests[1])
        #expect(payload["method"] as? String == "group-set")
        let args = try #require(payload["arguments"] as? [String: Any])
        #expect(Set(args.keys) == ["name", "honorsSessionLimits", "speed-limit-up"])
        #expect(args["honorsSessionLimits"] as? Bool == false)
    }

    @Test func assignmentUsesCapturedHashesAndVerifiesReadback() async throws {
        let before = #"{"result":"success","arguments":{"torrents":[{"hashString":"hash-a","group":""}]}}"#
        let after = #"{"result":"success","arguments":{"torrents":[{"hashString":"hash-a","group":"Slow"}]}}"#
        let c = try client([.init(body: before), .init(), .init(body: after)])
        try await c.assignBandwidthGroup("Slow", baseline: [.init(hashString: "hash-a", group: "")])
        #expect(OptionsURLProtocol.requests.count == 3)
        let payload = try body(OptionsURLProtocol.requests[1])
        #expect(payload["method"] as? String == "torrent-set")
        let args = try #require(payload["arguments"] as? [String: Any])
        #expect(args["ids"] as? [String] == ["hash-a"])
        #expect(args["group"] as? String == "Slow")
    }

    @Test(arguments: [#"{"result":"success","arguments":{"torrents":[]}}"#, #"{"result":"success","arguments":{"torrents":[{"hashString":"hash-a","group":"Other"}]}}"#])
    func changedOrRemovedTorrentBlocksGroupAssignment(_ reply: String) async throws {
        let c = try client([.init(body: reply)])
        await #expect(throws: ServerOptionsError.self) {
            try await c.assignBandwidthGroup("Slow", baseline: [.init(hashString: "hash-a", group: "")])
        }
        #expect(OptionsURLProtocol.requests.count == 1)
    }

    @Test func lostGroupAssignmentReplyIsNotRetried() async throws {
        let before = #"{"result":"success","arguments":{"torrents":[{"hashString":"hash-a","group":""}]}}"#
        let c = try client([.init(body: before), .init(status: 504)])
        await #expect(throws: TransmissionError.self) {
            try await c.assignBandwidthGroup("Slow", baseline: [.init(hashString: "hash-a", group: "")])
        }
        #expect(OptionsURLProtocol.requests.count == 2)
    }

    @Test(arguments: ["{}", "null", "[]", "42"])
    func failedSessionResponsePreservesServerErrorBeforeDecodingArguments(_ arguments: String) async throws {
        let message = "session service unavailable"
        let c = try client([.init(body: "{\"result\":\"\(message)\",\"arguments\":\(arguments)}")])
        do {
            _ = try await c.fetchServerOptions()
            Issue.record("Expected a server error")
        } catch TransmissionError.rpcError(let actual) {
            #expect(actual == message)
        } catch {
            Issue.record("The server error was masked by: \(error.localizedDescription)")
        }
        #expect(OptionsURLProtocol.requests.count == 1)
    }

    @Test func failedPortResponsePreservesServerErrorInsteadOfReportingClosed() async throws {
        let c = try client([.init(body: #"{"result":"port test service unavailable","arguments":{}}"#)])
        do {
            _ = try await c.testPeerPort(protocol: .ipv4)
            Issue.record("Expected a server error")
        } catch TransmissionError.rpcError(let message) {
            #expect(message == "port test service unavailable")
        } catch {
            Issue.record("The server error was masked by: \(error.localizedDescription)")
        }
    }

}
