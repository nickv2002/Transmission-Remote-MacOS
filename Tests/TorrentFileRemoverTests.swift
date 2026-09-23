import XCTest

final class TorrentFileRemoverTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    /// Trashed copies land outside `tmp` (in the real ~/.Trash), so any test that
    /// successfully trashes a file must record its resulting URL here for cleanup.
    private var trashedURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in trashedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeTorrentFile() throws -> URL {
        let url = tmp.appendingPathComponent("sample-\(UUID().uuidString).torrent")
        try Data("d4:infoe".utf8).write(to: url)
        return url
    }

    func testDeleteRemovesFile() throws {
        let url = try makeTorrentFile()
        try removeTorrentFile(at: url, method: .delete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTrashMovesFile() throws {
        let url = try makeTorrentFile()
        let trashedURL = try removeTorrentFile(at: url, method: .trash)
        if let trashedURL { trashedURLs.append(trashedURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(trashedURL)
    }

    func testDeleteMissingFileThrows() {
        let url = tmp.appendingPathComponent("missing.torrent")
        XCTAssertThrowsError(try removeTorrentFile(at: url, method: .delete))
    }
}
