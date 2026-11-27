import Foundation
import XCTest

/// Pure detection rules for clickable links in torrent comments: protocol-only.
final class LinkTextTests: XCTestCase {

    func testDetectsHttpAndHttpsLinks() {
        let text = "grab it here https://example.com/torrent?id=1 and mirror http://85.17.19.2/dl.torrent"
        let links = LinkText.links(in: text)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].url, URL(string: "https://example.com/torrent?id=1"))
        XCTAssertEqual(links[1].url, URL(string: "http://85.17.19.2/dl.torrent"))
    }

    func testRangesPointAtTheMatchedSubstrings() {
        let text = "see https://example.com now"
        let links = LinkText.links(in: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual((text as NSString).substring(with: links[0].range), "https://example.com")
    }

    func testBareDomainsAreNotLinks() {
        XCTAssertTrue(LinkText.links(in: "uploaded by rutracker.org, mirror example.com").isEmpty)
    }

    func testOtherSchemesAreNotLinks() {
        XCTAssertTrue(LinkText.links(
            in: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567").isEmpty)
        XCTAssertTrue(LinkText.links(in: "mailto:someone@example.com ftp://files.example.com/x").isEmpty)
    }

    func testPlainAndEmptyTextHaveNoLinks() {
        XCTAssertTrue(LinkText.links(in: "").isEmpty)
        XCTAssertTrue(LinkText.links(in: "just a comment, 100% pure").isEmpty)
    }
}
