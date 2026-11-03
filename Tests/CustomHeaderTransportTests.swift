import Foundation
import Testing

@Suite("Custom headers only travel over safe connections")
struct CustomHeaderTransportTests {
    private func server(host: String, https: Bool) -> ServerConfig {
        ServerConfig(name: "S", host: host, port: 9091, useHTTPS: https, rpcPath: "/transmission/rpc", headers: [CustomHeader(name: "X-T", value: "v")])
    }

    @Test func httpsHostsGetHeaders() { #expect(server(host: "nas.example", https: true).sendsCustomHeaders) }
    @Test func plainHttpHostsDoNot() { #expect(!server(host: "10.0.1.2", https: false).sendsCustomHeaders) }
    @Test func loopbackIsExempt() {
        for host in ["localhost", "127.0.0.1", "::1"] { #expect(server(host: host, https: false).sendsCustomHeaders) }
    }
    @Test func controlCharactersInValuesAreRejected() {
        let issue = HeaderValidation.issue(at: 0, in: [CustomHeader(name: "X-T", value: "a\u{0}b")])
        #expect(issue == .valueHasControlCharacter)
        #expect(HeaderValidation.issue(at: 0, in: [CustomHeader(name: "X-T", value: "a\tb")]) == nil)
    }
}
