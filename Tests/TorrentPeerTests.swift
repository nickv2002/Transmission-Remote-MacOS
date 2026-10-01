import XCTest
import Foundation

/// Decoding + sorting for the Peers tab (`TorrentPeer` / `PeerSortKey` /
/// `TorrentPeersArguments` in `Models.swift`).
final class TorrentPeerTests: XCTestCase {
    private func peer(_ dict: [String: Any]) -> TorrentPeer {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(TorrentPeer.self, from: data)
    }

    // MARK: - Decoding

    func testDecodeFullPeer() {
        let p = peer([
            "address": "10.0.1.24",
            "port": 51413,
            "clientName": "Transmission 4.1.2",
            "flagStr": "D U X I",
            "progress": 0.42,
            "rateToClient": 1024,
            "rateToPeer": 0,
            "isEncrypted": true,
            "isIncoming": true,
            "isUTP": false,
            "isDownloadingFrom": true,
            "isUploadingTo": false,
        ])
        XCTAssertEqual(p.address, "10.0.1.24")
        XCTAssertEqual(p.port, 51413)
        XCTAssertEqual(p.clientName, "Transmission 4.1.2")
        XCTAssertEqual(p.flagStr, "D U X I")
        XCTAssertEqual(p.progress, 0.42)
        XCTAssertEqual(p.rateToClient, 1024)
        XCTAssertEqual(p.rateToPeer, 0)
        XCTAssertTrue(p.isEncrypted)
        XCTAssertTrue(p.isIncoming)
        XCTAssertFalse(p.isUTP)
        XCTAssertTrue(p.isDownloadingFrom)
        XCTAssertFalse(p.isUploadingTo)
        XCTAssertEqual(p.id, "10.0.1.24:51413")
    }

    func testDecodeToleratesOmittedFields() {
        // Daemons omit zero-valued fields — the legacy app guarded those with
        // `IndexOfName`; everything but the address defaults here.
        let p = peer(["address": "192.168.1.5"])
        XCTAssertEqual(p.address, "192.168.1.5")
        XCTAssertEqual(p.port, 0)
        XCTAssertEqual(p.clientName, "")
        XCTAssertEqual(p.flagStr, "")
        XCTAssertEqual(p.progress, 0)
        XCTAssertEqual(p.rateToClient, 0)
        XCTAssertEqual(p.rateToPeer, 0)
        XCTAssertFalse(p.isEncrypted)
        XCTAssertFalse(p.isIncoming)
        XCTAssertFalse(p.isUTP)
        XCTAssertFalse(p.isDownloadingFrom)
        XCTAssertFalse(p.isUploadingTo)
    }

    func testDecodeRequiresAddress() {
        let data = try! JSONSerialization.data(withJSONObject: [String: Any]())
        XCTAssertThrowsError(try JSONDecoder().decode(TorrentPeer.self, from: data))
    }

    func testDecodePeersArgumentsEnvelope() {
        let json = """
        {"result":"success","arguments":{"torrents":[
            {"id":7,"peers":[{"address":"10.0.0.2","port":1},{"address":"10.0.0.3","port":2}]},
            {"id":9,"peers":[]}]}}
        """
        let decoded = try! JSONDecoder().decode(RPCResponse<TorrentPeersArguments>.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(decoded.result, "success")
        XCTAssertEqual(decoded.arguments?.torrents.count, 2)
        XCTAssertEqual(decoded.arguments?.torrents[0].id, 7)
        XCTAssertEqual(decoded.arguments?.torrents[0].peers.map(\.id), ["10.0.0.2:1", "10.0.0.3:2"])
        XCTAssertEqual(decoded.arguments?.torrents[1].peers, [])
    }

    // MARK: - Sorting

    private let sample: [TorrentPeer] = [
        TorrentPeer(address: "10.0.0.10", port: 51413, clientName: "qBittorrent 4.6",
                    flagStr: "U", progress: 1.0, rateToClient: 0, rateToPeer: 5000),
        TorrentPeer(address: "10.0.0.2", port: 51411, clientName: "Transmission 4.1.2",
                    flagStr: "D U", progress: 0.25, rateToClient: 120_000, rateToPeer: 0),
        TorrentPeer(address: "10.0.0.2", port: 51412, clientName: "libtorrent 2.0",
                    flagStr: "D", progress: 0.75, rateToClient: 12_000, rateToPeer: 300),
    ]

    func testUnsortedKeepsServerOrder() {
        let sorted = PeerSortKey.sorted(sample, by: nil, ascending: true)
        XCTAssertTrue(sorted.elementsEqual(sample))
    }

    func testSortByAddressIsNumericAndTiesBreakOnPort() {
        // Numeric-aware: "10.0.0.2" orders before "10.0.0.10" (Finder-style,
        // not lexicographic); the equal-address pair ties on port ascending.
        let asc = PeerSortKey.sorted(sample, by: .address, ascending: true)
        XCTAssertEqual(asc.map(\.id), ["10.0.0.2:51411", "10.0.0.2:51412", "10.0.0.10:51413"])
        let desc = PeerSortKey.sorted(sample, by: .address, ascending: false)
        XCTAssertEqual(desc.map(\.id), ["10.0.0.10:51413", "10.0.0.2:51411", "10.0.0.2:51412"])
    }

    func testSortByClientIsCaseInsensitive() {
        let asc = PeerSortKey.sorted(sample, by: .client, ascending: true)
        XCTAssertEqual(asc.map(\.clientName), ["libtorrent 2.0", "qBittorrent 4.6", "Transmission 4.1.2"])
        let desc = PeerSortKey.sorted(sample, by: .client, ascending: false)
        XCTAssertEqual(desc.map(\.clientName), ["Transmission 4.1.2", "qBittorrent 4.6", "libtorrent 2.0"])
    }

    func testSortByFlags() {
        let asc = PeerSortKey.sorted(sample, by: .flags, ascending: true)
        XCTAssertEqual(asc.map(\.flagStr), ["D", "D U", "U"])
    }

    func testSortByProgress() {
        let asc = PeerSortKey.sorted(sample, by: .progress, ascending: true)
        XCTAssertEqual(asc.map(\.progress), [0.25, 0.75, 1.0])
        let desc = PeerSortKey.sorted(sample, by: .progress, ascending: false)
        XCTAssertEqual(desc.map(\.progress), [1.0, 0.75, 0.25])
    }

    func testSortByRates() {
        let downs = PeerSortKey.sorted(sample, by: .down, ascending: true)
        XCTAssertEqual(downs.map(\.rateToClient), [0, 12_000, 120_000])
        let ups = PeerSortKey.sorted(sample, by: .up, ascending: false)
        XCTAssertEqual(ups.map(\.rateToPeer), [5000, 300, 0])
    }

    func testTiesBreakByAddressAscendingRegardlessOfDirection() {
        // Equal primary values keep a stable order across poll reloads —
        // ascending by address whether the sort itself ascends or descends.
        let peers = [
            TorrentPeer(address: "10.0.0.9", port: 1, progress: 0.5),
            TorrentPeer(address: "10.0.0.2", port: 1, progress: 0.5),
        ]
        let asc = PeerSortKey.sorted(peers, by: .progress, ascending: true)
        XCTAssertEqual(asc.map(\.address), ["10.0.0.2", "10.0.0.9"])
        let desc = PeerSortKey.sorted(peers, by: .progress, ascending: false)
        XCTAssertEqual(desc.map(\.address), ["10.0.0.2", "10.0.0.9"])
    }
}
