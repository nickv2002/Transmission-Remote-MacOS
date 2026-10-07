import XCTest
import Foundation

/// Decoding + downsampling for the Info tab's piece map (`TorrentPieces` /
/// `TorrentPiecesArguments` in `Models.swift`).
final class TorrentPiecesTests: XCTestCase {
    private func pieces(_ dict: [String: Any]) -> TorrentPieces {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(TorrentPieces.self, from: data)
    }

    private func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    // MARK: - Decoding

    func testDecodeBitfieldMostSignificantBitFirst() {
        // 0b1010_0000 → pieces 0 and 2 present, 1 and 3 absent (legacy walks $80 down).
        let p = pieces(["id": 7, "pieceCount": 4, "pieceSize": 4_194_304, "pieces": base64([0xA0])])
        XCTAssertEqual(p.pieceCount, 4)
        XCTAssertEqual(p.pieceSize, 4_194_304)
        XCTAssertTrue(p.has(0))
        XCTAssertFalse(p.has(1))
        XCTAssertTrue(p.has(2))
        XCTAssertFalse(p.has(3))
        XCTAssertEqual(p.haveCount, 2)
    }

    func testDecodeToleratesOmittedFields() {
        // A magnet still fetching metadata has no pieces at all; daemons omit zeros.
        let p = pieces(["id": 7])
        XCTAssertEqual(p.pieceCount, 0)
        XCTAssertEqual(p.pieceSize, 0)
        XCTAssertEqual(p.bitfield, Data())
        XCTAssertEqual(p.haveCount, 0)
        XCTAssertFalse(p.has(0))
    }

    func testDecodeInvalidBase64FallsBackToEmptyBitfield() {
        let p = pieces(["pieceCount": 8, "pieces": "not base64!!"])
        XCTAssertEqual(p.bitfield, Data())
        XCTAssertEqual(p.haveCount, 0)
    }

    func testDecodeBoundsHostilePieceCountByBitfield() {
        // A daemon claiming Int.max pieces with a one-byte bitfield must neither
        // hang `coverage` nor trap on Double→Int conversion; the count is bounded
        // by the bits actually sent. Negative values clamp to zero.
        let hostile = pieces(["pieceCount": Int.max, "pieceSize": -5, "pieces": base64([0xF0])])
        XCTAssertEqual(hostile.pieceCount, 8)
        XCTAssertEqual(hostile.pieceSize, 0)
        XCTAssertEqual(hostile.haveCount, 4)
        XCTAssertEqual(hostile.coverage(columns: 2), [1, 0])
        XCTAssertEqual(hostile.summary, "4 of 8 pieces")
        let negative = pieces(["pieceCount": -3, "pieces": base64([0xFF])])
        XCTAssertEqual(negative.pieceCount, 0)
        XCTAssertEqual(negative.coverage(columns: 3), [0, 0, 0])
        // Legitimate counts (bitfield padded to whole bytes) are unchanged.
        XCTAssertEqual(pieces(["pieceCount": 1017, "pieces": base64([UInt8](repeating: 0xFF, count: 128))]).pieceCount, 1017)
    }

    func testCoverageNeverWalksPastShortBitfield() {
        // Memberwise init keeps the reported count, but coverage only walks the
        // bits present: 1 byte of data behind a 1_000_000-piece claim stays fast.
        let p = TorrentPieces(pieceCount: 1_000_000, bitfield: Data([0xFF]))
        let c = p.coverage(columns: 4)
        XCTAssertEqual(c.count, 4)
        XCTAssertEqual(c[0], 8.0 / 250_000.0, accuracy: 1e-12)
        XCTAssertEqual(c[1...3].max(), 0)
    }

    func testDecodeArgumentsWrapper() {
        let json: [String: Any] = [
            "torrents": [["id": 3, "pieceCount": 2, "pieceSize": 16, "pieces": base64([0xC0])]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let args = try! JSONDecoder().decode(TorrentPiecesArguments.self, from: data)
        XCTAssertEqual(args.torrents.count, 1)
        XCTAssertEqual(args.torrents.first?.haveCount, 2)
    }

    // MARK: - has / haveCount

    func testHasIgnoresPaddingBitsBeyondPieceCount() {
        // 0xFF with only 3 pieces: bits 3–7 are padding.
        let p = TorrentPieces(pieceCount: 3, bitfield: Data([0xFF]))
        XCTAssertTrue(p.has(2))
        XCTAssertFalse(p.has(3))
        XCTAssertFalse(p.has(-1))
        XCTAssertEqual(p.haveCount, 3)
    }

    func testHasIsFalseBeyondShortBitfield() {
        // pieceCount says 16 but the daemon sent one byte.
        let p = TorrentPieces(pieceCount: 16, bitfield: Data([0xFF]))
        XCTAssertTrue(p.has(7))
        XCTAssertFalse(p.has(8))
        XCTAssertEqual(p.haveCount, 8)
    }

    func testHaveCountSpansMultipleBytesWithPartialTail() {
        // 12 pieces: first byte full, second byte 0b1111_0000 plus junk padding 0b0000_1111.
        let p = TorrentPieces(pieceCount: 12, bitfield: Data([0xFF, 0xFF]))
        XCTAssertEqual(p.haveCount, 12)
        let q = TorrentPieces(pieceCount: 12, bitfield: Data([0xFF, 0x0F]))
        XCTAssertEqual(q.haveCount, 8, "padding bits must not count")
    }

    // MARK: - coverage

    func testCoverageExactWhenColumnsMatchPieces() {
        let p = TorrentPieces(pieceCount: 4, bitfield: Data([0xA0]))
        XCTAssertEqual(p.coverage(columns: 4), [1, 0, 1, 0])
    }

    func testCoverageAveragesWhenFewerColumnsThanPieces() {
        // 8 pieces 0b1100_1000 → two columns of four: [1,1,0,0]=0.5, [1,0,0,0]=0.25.
        let p = TorrentPieces(pieceCount: 8, bitfield: Data([0xC8]))
        let c = p.coverage(columns: 2)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(c[1], 0.25, accuracy: 1e-9)
    }

    func testCoverageSpreadsWhenMoreColumnsThanPieces() {
        // 2 pieces, first present → four columns: the first two are 1, the rest 0.
        let p = TorrentPieces(pieceCount: 2, bitfield: Data([0x80]))
        XCTAssertEqual(p.coverage(columns: 4), [1, 1, 0, 0])
    }

    func testCoverageWeightsColumnsStraddlingAPieceBoundary() {
        // 3 pieces (present, absent, present) over 2 columns of 1.5 pieces each:
        // column 0 = piece 0 (1.0) + half of piece 1 (0) → 1/1.5; column 1 = other
        // half of piece 1 (0) + piece 2 (1.0) → 1/1.5.
        let p = TorrentPieces(pieceCount: 3, bitfield: Data([0xA0]))
        let c = p.coverage(columns: 2)
        XCTAssertEqual(c[0], 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(c[1], 2.0 / 3.0, accuracy: 1e-9)
    }

    func testCoverageEdgeCases() {
        XCTAssertEqual(TorrentPieces(pieceCount: 4, bitfield: Data([0xF0])).coverage(columns: 0), [])
        XCTAssertEqual(TorrentPieces(pieceCount: 0).coverage(columns: 3), [0, 0, 0])
        // A complete torrent is solid across any width.
        let full = TorrentPieces(pieceCount: 10, bitfield: Data([0xFF, 0xC0]))
        XCTAssertEqual(full.coverage(columns: 7), Array(repeating: 1.0, count: 7))
    }

    func testCoverageLargeBitfieldStaysBounded() {
        // ~40k pieces alternating present/absent → every column near 0.5, all within [0, 1].
        let bytes = [UInt8](repeating: 0xAA, count: 5_000)
        let p = TorrentPieces(pieceCount: 40_000, bitfield: Data(bytes))
        let c = p.coverage(columns: 1_000)
        XCTAssertEqual(c.count, 1_000)
        for v in c { XCTAssertEqual(v, 0.5, accuracy: 1e-9) }
    }

    // MARK: - summary

    func testSummaryText() {
        XCTAssertEqual(TorrentPieces(pieceCount: 0).summary, "No pieces yet")
        let p = TorrentPieces(pieceCount: 4, pieceSize: 4_194_304, bitfield: Data([0xA0]))
        XCTAssertEqual(p.summary, "2 of 4 pieces · \(Formatters.size(4_194_304)) each")
        let noSize = TorrentPieces(pieceCount: 4, bitfield: Data([0xA0]))
        XCTAssertEqual(noSize.summary, "2 of 4 pieces")
    }
}
