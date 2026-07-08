import XCTest

final class PathMappingTests: XCTestCase {
    private func server(_ mappings: [PathMapping]) -> ServerConfig {
        ServerConfig(name: "S", host: "h", port: 9091, useHTTPS: false,
                     rpcPath: "/transmission/rpc", pathMappings: mappings)
    }

    private func map(_ remote: String, _ rules: [(String, String)]) -> String? {
        server(rules.map { PathMapping(remote: $0.0, local: $0.1) }).mapRemoteToLocal(remote)
    }

    // MARK: - mapRemoteToLocal

    func testPrefixMatchRewritesRemainder() {
        // The owner's real case.
        XCTAssertEqual(map("/video/Show/ep.mkv", [("/video", "/Volumes/Video")]),
                       "/Volumes/Video/Show/ep.mkv")
    }

    func testExactMatchReturnsLocalAsIs() {
        XCTAssertEqual(map("/video", [("/video", "/Volumes/Video")]), "/Volumes/Video")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(map("/music/x.flac", [("/video", "/Volumes/Video")]))
    }

    func testEmptyMappingsReturnsNil() {
        XCTAssertNil(map("/video/x", []))
    }

    func testEqualLengthPrefixTiesFallBackToListOrder() {
        // With no specificity difference between mappings, list order still
        // decides ties (matches the pre-existing, non-overlapping-case behavior).
        let rules = [("/video", "/Volumes/First"), ("/video", "/Volumes/Second")]
        XCTAssertEqual(map("/video/x", rules), "/Volumes/First/x")
    }

    func testLongestPrefixWinsRegardlessOfListOrder_broaderFirst() {
        // REPRODUCTION for the owner-reported bug: a broader first-line mapping
        // must not swallow a path meant for a more specific second-line mapping.
        let rules = [("/video", "/Volumes/Video"), ("/video/4k", "/Volumes/Video4K")]
        XCTAssertEqual(map("/video/4k/movie.mp4", rules), "/Volumes/Video4K/movie.mp4")
    }

    func testLongestPrefixWinsRegardlessOfListOrder_broaderSecond() {
        // Same overlap, mappings reversed — order must not matter.
        let rules = [("/video/4k", "/Volumes/Video4K"), ("/video", "/Volumes/Video")]
        XCTAssertEqual(map("/video/4k/movie.mp4", rules), "/Volumes/Video4K/movie.mp4")
    }

    func testExactMatchStillWinsOverLongerPrefixMapping() {
        // An exact match on a mapping's remote side takes priority outright, even
        // if another mapping's prefix is textually longer.
        let rules = [("/video/4k", "/Volumes/Video4K"), ("/video", "/Volumes/Video")]
        XCTAssertEqual(map("/video", rules), "/Volumes/Video")
    }

    func testDisjointMappingsUnaffectedByOrder() {
        // Non-overlapping mappings still resolve correctly regardless of order —
        // the original "first match wins" scenario had no specificity ambiguity.
        let rules = [("/video", "/Volumes/Video"), ("/undupe", "/Volumes/undupe")]
        XCTAssertEqual(map("/video/x", rules), "/Volumes/Video/x")
        XCTAssertEqual(map("/undupe/y", rules), "/Volumes/undupe/y")
    }

    func testPrefixGuardedBySeparator() {
        // `/var` must not match `/var2` — the trailing-slash guard prevents it.
        XCTAssertNil(map("/var2/file", [("/var", "/Volumes/Var")]))
        XCTAssertEqual(map("/var/file", [("/var", "/Volumes/Var")]), "/Volumes/Var/file")
    }

    func testTrailingSlashesNormalized() {
        // Trailing slash on either side shouldn't double the separator.
        XCTAssertEqual(map("/video/x", [("/video/", "/Volumes/Video/")]),
                       "/Volumes/Video/x")
    }

    func testWhitespaceTrimmedAroundPath() {
        XCTAssertEqual(map("  /video/x  ", [("/video", "/Volumes/Video")]),
                       "/Volumes/Video/x")
    }

    func testCaseSensitive() {
        XCTAssertNil(map("/Video/x", [("/video", "/Volumes/Video")]))
    }

    // MARK: - mapLocalToRemote

    private func reverseMap(_ local: String, _ rules: [(String, String)]) -> String? {
        server(rules.map { PathMapping(remote: $0.0, local: $0.1) }).mapLocalToRemote(local)
    }

    func testReversePrefixMatchRewritesRemainder() {
        XCTAssertEqual(reverseMap("/Volumes/Video/Show/ep.mkv", [("/video", "/Volumes/Video")]),
                       "/video/Show/ep.mkv")
    }

    func testReverseExactMatchReturnsRemoteAsIs() {
        XCTAssertEqual(reverseMap("/Volumes/Video", [("/video", "/Volumes/Video")]), "/video")
    }

    func testReverseNoMatchReturnsNil() {
        XCTAssertNil(reverseMap("/Volumes/Music/x.flac", [("/video", "/Volumes/Video")]))
    }

    func testReverseEmptyMappingsReturnsNil() {
        XCTAssertNil(reverseMap("/Volumes/Video/x", []))
    }

    func testReversePrefixGuardedBySeparator() {
        // `/Volumes/Var` must not match `/Volumes/Var2` — the trailing-slash guard prevents it.
        XCTAssertNil(reverseMap("/Volumes/Var2/file", [("/var", "/Volumes/Var")]))
        XCTAssertEqual(reverseMap("/Volumes/Var/file", [("/var", "/Volumes/Var")]), "/var/file")
    }

    func testReverseLongestPrefixWins() {
        // Overlapping mappings: the longer, more specific local prefix should win —
        // unlike the legacy Pascal `SelectRemoteFolder`, which had no `break` and let
        // list order (last match) decide ties instead.
        let rules = [("/video", "/Volumes/Video"), ("/video/Show", "/Volumes/Video/Show")]
        XCTAssertEqual(reverseMap("/Volumes/Video/Show/ep.mkv", rules), "/video/Show/ep.mkv")
    }

    func testReverseLongestPrefixWinsRegardlessOfListOrder() {
        let rules = [("/video/Show", "/Volumes/Video/Show"), ("/video", "/Volumes/Video")]
        XCTAssertEqual(reverseMap("/Volumes/Video/Show/ep.mkv", rules), "/video/Show/ep.mkv")
    }

    func testReverseTrailingSlashesNormalized() {
        XCTAssertEqual(reverseMap("/Volumes/Video/x", [("/video/", "/Volumes/Video/")]),
                       "/video/x")
    }

    func testReverseWhitespaceTrimmedAroundPath() {
        XCTAssertEqual(reverseMap("  /Volumes/Video/x  ", [("/video", "/Volumes/Video")]),
                       "/video/x")
    }

    func testReverseCaseSensitive() {
        XCTAssertNil(reverseMap("/Volumes/video/x", [("/video", "/Volumes/Video")]))
    }

    // MARK: - parse / format

    func testParseSplitsLinesOnFirstEquals() {
        let text = "/video=/Volumes/Video\n/undupe=/Volumes/undupe"
        XCTAssertEqual(PathMapping.parse(text), [
            PathMapping(remote: "/video", local: "/Volumes/Video"),
            PathMapping(remote: "/undupe", local: "/Volumes/undupe"),
        ])
    }

    func testParseTrimsAndSkipsBlankOrInvalidLines() {
        let text = "  /a = /b \n\n   \nno-equals-here\n/c=\n=/d"
        XCTAssertEqual(PathMapping.parse(text), [PathMapping(remote: "/a", local: "/b")])
    }

    func testParseKeepsEqualsInLocalPath() {
        // Only the first '=' splits; later ones belong to the local side.
        XCTAssertEqual(PathMapping.parse("/a=/b=c"),
                       [PathMapping(remote: "/a", local: "/b=c")])
    }

    func testFormatRoundTrip() {
        let mappings = [
            PathMapping(remote: "/video", local: "/Volumes/Video"),
            PathMapping(remote: "/undupe", local: "/Volumes/undupe"),
        ]
        XCTAssertEqual(PathMapping.parse(PathMapping.format(mappings)), mappings)
    }
}
