import Foundation

/// An in-memory IP-to-country table built from the DB-IP "IP to Country Lite"
/// CSV (`start,end,CC` per line, IPv4 and IPv6). Foundation-only so it can be
/// unit-tested; `GeoIPStore` owns the download and the file on disk.
///
/// Data: IP to Country Lite by DB-IP.com, licensed CC BY 4.0
/// (https://db-ip.com/db/download/ip-to-country-lite).
struct GeoIPDatabase: Sendable {
    private var v4Starts: [UInt32] = []
    private var v4Ends: [UInt32] = []
    private var v4Codes: [UInt16] = []
    private var v6Starts: [UInt128] = []
    private var v6Ends: [UInt128] = []
    private var v6Codes: [UInt16] = []

    var count: Int { v4Starts.count + v6Starts.count }
    var isEmpty: Bool { count == 0 }

    /// Parses CSV text; malformed lines are skipped. Input is expected sorted
    /// (DB-IP's is); it's sorted here if not, so lookups stay correct.
    init(csv: String) {
        var v4: [(UInt32, UInt32, UInt16)] = []
        var v6: [(UInt128, UInt128, UInt16)] = []
        csv.enumerateLines { line, _ in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, let code = Self.pack(parts[2].trimmingCharacters(in: .whitespaces)) else { return }
            if let a = Self.parseV4(parts[0]), let b = Self.parseV4(parts[1]) {
                v4.append((a, b, code))
            } else if let a = Self.parseV6(parts[0]), let b = Self.parseV6(parts[1]) {
                v6.append((a, b, code))
            }
        }
        v4.sort { $0.0 < $1.0 }
        v6.sort { $0.0 < $1.0 }
        v4Starts = v4.map(\.0); v4Ends = v4.map(\.1); v4Codes = v4.map(\.2)
        v6Starts = v6.map(\.0); v6Ends = v6.map(\.1); v6Codes = v6.map(\.2)
    }

    /// Parses a gzip-compressed CSV (the file DB-IP publishes). Nil if the data
    /// isn't gzip, doesn't inflate, or yields no ranges.
    init?(gzipped data: Data) {
        guard let raw = Self.gunzip(data), let text = String(data: raw, encoding: .utf8) else { return nil }
        self.init(csv: text)
        if isEmpty { return nil }
    }

    /// Upper-case ISO 3166 alpha-2 code for an IP literal, or nil when unknown
    /// (or DB-IP's "ZZ" placeholder).
    func country(for address: String) -> String? {
        var code: UInt16?
        if let ip = Self.parseV4(address[...]) {
            code = Self.lookup(ip, starts: v4Starts, ends: v4Ends, codes: v4Codes)
        } else if let ip = Self.parseV6(address[...]) {
            if let mapped = Self.v4Mapped(ip) {
                code = Self.lookup(mapped, starts: v4Starts, ends: v4Ends, codes: v4Codes)
            } else {
                code = Self.lookup(ip, starts: v6Starts, ends: v6Ends, codes: v6Codes)
            }
        }
        guard let code, let text = Self.unpack(code), text != "ZZ" else { return nil }
        return text
    }

    /// Flag emoji for an alpha-2 code ("US" → 🇺🇸), or "" for anything else.
    static func flag(for code: String) -> String {
        let scalars = code.uppercased().unicodeScalars
        guard scalars.count == 2, scalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return "" }
        return String(String.UnicodeScalarView(scalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
    }

    // MARK: - Internals

    private static func lookup<T: FixedWidthInteger>(_ ip: T, starts: [T], ends: [T], codes: [UInt16]) -> UInt16? {
        // Last range whose start <= ip.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= ip { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, ip <= ends[lo - 1] else { return nil }
        return codes[lo - 1]
    }

    private static func pack(_ s: String) -> UInt16? {
        let u = Array(s.uppercased().utf8)
        guard u.count == 2, u.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return nil }
        return UInt16(u[0]) << 8 | UInt16(u[1])
    }

    private static func unpack(_ v: UInt16) -> String? {
        String(bytes: [UInt8(v >> 8), UInt8(v & 0xFF)], encoding: .ascii)
    }

    private static func parseV4(_ s: Substring) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, String(s), &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func parseV6(_ s: Substring) -> UInt128? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, String(s), &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { raw in
            raw.reduce(UInt128(0)) { $0 << 8 | UInt128($1) }
        }
    }

    /// ::ffff:a.b.c.d → the embedded IPv4 address.
    private static func v4Mapped(_ ip: UInt128) -> UInt32? {
        (ip >> 32) == UInt128(0xFFFF) ? UInt32(truncatingIfNeeded: ip) : nil
    }

    /// Strips the gzip wrapper (RFC 1952) and inflates the raw deflate stream.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let deflate = Data(b[i..<(b.count - 8)])
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
