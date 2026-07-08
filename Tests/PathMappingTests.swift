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

    // MARK: - resolveLocalPath (drives Reveal/Open/Quick Look/drag-out toasts)

    func testResolveLocalPathUnmappedWhenNoMappingMatches() {
        let s = server([PathMapping(remote: "/video", local: "/Volumes/Video")])
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/music/x.flac", fileExists: { _ in true }), .unmapped)
    }

    func testResolveLocalPathNotFoundWhenMappedButMissing() {
        let s = server([PathMapping(remote: "/video", local: "/Volumes/Video")])
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/video/x.mkv", fileExists: { _ in false }),
                       .notFound(path: "/Volumes/Video/x.mkv"))
    }

    func testResolveLocalPathAvailableWhenMappedAndPresent() {
        let s = server([PathMapping(remote: "/video", local: "/Volumes/Video")])
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/video/x.mkv", fileExists: { _ in true }),
                       .available(path: "/Volumes/Video/x.mkv"))
    }

    /// The owner's reported scenario: two genuinely disjoint mappings. Both lines
    /// must resolve — and report "available" when their file actually exists —
    /// identically, regardless of which line matched. This is the synthetic
    /// reproduction attempt for the "drag out only works for line 1" bug: if this
    /// passes, the resolution layer itself has no line-1-vs-line-2 asymmetry.
    func testResolveLocalPathBothDisjointLinesResolveAndReportAvailableIdentically() {
        let s = server([
            PathMapping(remote: "/video", local: "/Volumes/Video"),
            PathMapping(remote: "/undupe", local: "/Volumes/undupe"),
        ])
        // Simulate: files exist under Video, don't exist under undupe.
        let existing: Set<String> = ["/Volumes/Video/Show/ep.mkv"]
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/video/Show/ep.mkv", fileExists: { existing.contains($0) }),
                       .available(path: "/Volumes/Video/Show/ep.mkv"))
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/undupe/Show/ep.mkv", fileExists: { existing.contains($0) }),
                       .notFound(path: "/Volumes/undupe/Show/ep.mkv"))
        // Now simulate both actually existing (real synthetic-directory setup) —
        // both lines must report .available, with no special-casing of line order.
        let bothExisting: Set<String> = ["/Volumes/Video/Show/ep.mkv", "/Volumes/undupe/Show/ep.mkv"]
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/video/Show/ep.mkv", fileExists: { bothExisting.contains($0) }),
                       .available(path: "/Volumes/Video/Show/ep.mkv"))
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/undupe/Show/ep.mkv", fileExists: { bothExisting.contains($0) }),
                       .available(path: "/Volumes/undupe/Show/ep.mkv"))
    }

    /// Same reproduction against the REAL filesystem (not an injected closure) —
    /// creates real files under two disjoint scratch directories and confirms
    /// `resolveLocalPath` treats both identically end-to-end, using the default
    /// `FileManager.default.fileExists` path (the exact code path drag-out and
    /// Reveal/Open actually use live).
    func testResolveLocalPathBothDisjointLinesAgainstRealFilesystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transgui-pathmap-\(UUID().uuidString)")
        let videoDir = root.appendingPathComponent("Video")
        let undupeDir = root.appendingPathComponent("undupe")
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: undupeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let videoFile = videoDir.appendingPathComponent("ep.mkv")
        let undupeFile = undupeDir.appendingPathComponent("ep2.mkv")
        FileManager.default.createFile(atPath: videoFile.path, contents: Data())
        FileManager.default.createFile(atPath: undupeFile.path, contents: Data())

        let s = server([
            PathMapping(remote: "/video", local: videoDir.path),
            PathMapping(remote: "/undupe", local: undupeDir.path),
        ])
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/video/ep.mkv"), .available(path: videoFile.path))
        XCTAssertEqual(s.resolveLocalPath(forRemotePath: "/undupe/ep2.mkv"), .available(path: undupeFile.path))
    }

    // MARK: - PathPermissions.blocksCrossProcessDrag

    func testBlocksCrossProcessDragForOwnerOnlyMode() {
        XCTAssertTrue(PathPermissions.blocksCrossProcessDrag(posixPermissions: 0o600))
        XCTAssertTrue(PathPermissions.blocksCrossProcessDrag(posixPermissions: 0o700))
    }

    func testDoesNotBlockCrossProcessDragWhenGroupOrOtherReadable() {
        XCTAssertFalse(PathPermissions.blocksCrossProcessDrag(posixPermissions: 0o644))
        XCTAssertFalse(PathPermissions.blocksCrossProcessDrag(posixPermissions: 0o664))
        XCTAssertFalse(PathPermissions.blocksCrossProcessDrag(posixPermissions: 0o604))
        XCTAssertFalse(PathPermissions.blocksCrossProcessDrag(posixPermissions: 0o640))
    }

    /// Same check against the real filesystem: an owner-only (600) real file
    /// blocks, a group/other-readable (644) real file doesn't — the exact
    /// distinction observed live between a real server's two shares.
    func testBlocksCrossProcessDragAtPathAgainstRealFilesystem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transgui-permcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let restricted = dir.appendingPathComponent("owner-only.mp4")
        let readable = dir.appendingPathComponent("group-readable.mp4")
        FileManager.default.createFile(atPath: restricted.path, contents: Data(),
                                        attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: readable.path, contents: Data(),
                                        attributes: [.posixPermissions: 0o644])

        XCTAssertTrue(PathPermissions.blocksCrossProcessDrag(atPath: restricted.path))
        XCTAssertFalse(PathPermissions.blocksCrossProcessDrag(atPath: readable.path))
    }

    func testBlocksCrossProcessDragAtPathMissingFileDoesNotBlock() {
        XCTAssertFalse(PathPermissions.blocksCrossProcessDrag(atPath: "/nonexistent/path/\(UUID().uuidString)"))
    }
}
