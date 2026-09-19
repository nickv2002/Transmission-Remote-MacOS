import XCTest

final class TorrentFileRemoverTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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

    func testTrashMovesFileAwayOrThrows() throws {
        let url = try makeTorrentFile()
        // Volumes without a Trash (some temp/network volumes) make trashItem
        // throw. Either the file is moved away, or the call throws and leaves
        // it untouched — never a silent no-op.
        do {
            try removeTorrentFile(at: url, method: .trash)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testDeleteMissingFileThrows() {
        let url = tmp.appendingPathComponent("missing.torrent")
        XCTAssertThrowsError(try removeTorrentFile(at: url, method: .delete))
    }
}
