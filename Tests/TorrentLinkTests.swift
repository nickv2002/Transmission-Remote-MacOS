import XCTest

final class TorrentLinkTests: XCTestCase {
    private let hex = "0123456789abcdef0123456789ABCDEF01234567"
    private let base32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    // MARK: - normalize (strict: clipboard)

    func testMagnetAcceptedAndTrimmed() {
        let magnet = "magnet:?xt=urn:btih:\(hex)&dn=Test"
        XCTAssertEqual(TorrentLink.normalize("  \(magnet)\n"), magnet)
    }

    func testMagnetPrefixIsCaseInsensitive() {
        XCTAssertEqual(TorrentLink.normalize("MAGNET:?xt=urn:btih:\(hex)"), "MAGNET:?xt=urn:btih:\(hex)")
    }

    func testHexInfoHashBecomesMagnet() {
        XCTAssertEqual(TorrentLink.normalize(hex), "magnet:?xt=urn:btih:\(hex)")
    }

    func testBase32InfoHashBecomesMagnet() {
        XCTAssertEqual(TorrentLink.normalize(base32.lowercased()),
                       "magnet:?xt=urn:btih:\(base32.lowercased())")
    }

    func testNearMissHashesRejected() {
        XCTAssertNil(TorrentLink.normalize(String(hex.dropLast())))        // 39 chars
        XCTAssertNil(TorrentLink.normalize(String(hex.dropLast()) + "g"))  // non-hex
        XCTAssertNil(TorrentLink.normalize("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")) // 0/1 aren't base32
    }

    func testTorrentURLAccepted() {
        let url = "https://example.com/files/Some.Linux.iso.torrent"
        XCTAssertEqual(TorrentLink.normalize(url), url)
        XCTAssertEqual(TorrentLink.normalize("http://example.com/a.TORRENT?key=1"),
                       "http://example.com/a.TORRENT?key=1")
    }

    func testPlainWebURLRejectedByStrict() {
        XCTAssertNil(TorrentLink.normalize("https://example.com/page.html"))
        XCTAssertNil(TorrentLink.normalize("https://example.com/download?id=5"))
    }

    func testGarbageRejected() {
        XCTAssertNil(TorrentLink.normalize(""))
        XCTAssertNil(TorrentLink.normalize("hello world"))
        XCTAssertNil(TorrentLink.normalize("/Users/me/file.torrent"))
        XCTAssertNil(TorrentLink.normalize("check out magnet:?xt=urn:btih:\(hex)"))
    }

    // MARK: - identity (repeat detection)

    func testIdentityIgnoresDisplayNameAndCase() {
        let a = "magnet:?xt=urn:btih:\(hex)&dn=My%20Show"
        let b = "magnet:?dn=My Show&xt=urn:btih:\(hex.lowercased())&tr=udp://t:1"
        XCTAssertEqual(TorrentLink.identity(of: a), TorrentLink.identity(of: b))
        XCTAssertEqual(TorrentLink.identity(of: a), hex.lowercased())
    }

    func testIdentityDistinguishesDifferentHashes() {
        XCTAssertNotEqual(TorrentLink.identity(of: "magnet:?xt=urn:btih:\(hex)"),
                          TorrentLink.identity(of: "magnet:?xt=urn:btih:\(base32)"))
    }

    func testIdentityFallsBackToLink() {
        let url = "https://example.com/a.torrent"
        XCTAssertEqual(TorrentLink.identity(of: url), url)
        XCTAssertEqual(TorrentLink.identity(of: "magnet:?dn=nohash"), "magnet:?dn=nohash")
    }

    // MARK: - acceptable (loose: drops / opened URLs)

    func testAcceptableAllowsAnyWebURL() {
        XCTAssertEqual(TorrentLink.acceptable(" https://example.com/download?id=5 "),
                       "https://example.com/download?id=5")
    }

    func testAcceptableStillNormalizesHashes() {
        XCTAssertEqual(TorrentLink.acceptable(hex), "magnet:?xt=urn:btih:\(hex)")
    }

    func testAcceptableRejectsTextWithSpaces() {
        XCTAssertNil(TorrentLink.acceptable("https://a.com/x and more"))
        XCTAssertNil(TorrentLink.acceptable("ftp://example.com/a.torrent"))
    }
}
