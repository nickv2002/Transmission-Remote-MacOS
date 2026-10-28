import Foundation

enum ServerTransports: String, CaseIterable, Sendable {
    case preferUTP = "utp,tcp", preferTCP = "tcp,utp", tcpOnly = "tcp", utpOnly = "utp", disabled = ""
    var protocols: [String] { rawValue.isEmpty ? [] : rawValue.components(separatedBy: ",") }
    var displayName: String {
        switch self {
        case .preferUTP: "Prefer µTP, allow TCP"
        case .preferTCP: "Prefer TCP, allow µTP"
        case .tcpOnly: "TCP only"
        case .utpOnly: "µTP only"
        case .disabled: "Disable peer transports"
        }
    }
}

enum PeerPortProtocol: String, CaseIterable, Sendable {
    case automatic, ipv4, ipv6
    var displayName: String {
        switch self { case .automatic: "Automatic"; case .ipv4: "IPv4"; case .ipv6: "IPv6" }
    }
}

struct PeerPortResult: Decodable, Sendable, Equatable {
    var isOpen: Bool
    var ipProtocol: String?
    enum CodingKeys: String, CodingKey { case isOpen = "port-is-open", ipProtocol = "ip_protocol" }

    func description(requested: PeerPortProtocol) -> String {
        let family = ipProtocol.map { PeerPortProtocol(rawValue: $0)?.displayName ?? $0 } ?? (requested == .automatic ? "Automatic test" : "\(requested.displayName) requested; protocol unconfirmed")
        return "\(family): the server’s current incoming port is \(isOpen ? "reachable" : "not reachable")."
    }
}



struct BandwidthGroup: Decodable, Equatable, Sendable {
    var name: String
    var honorsSessionLimits: Bool
    var downEnabled: Bool
    var down: Int
    var upEnabled: Bool
    var up: Int

    enum CodingKeys: String, CodingKey {
        case name, honorsSessionLimits
        case downEnabled = "speed-limit-down-enabled", down = "speed-limit-down"
        case upEnabled = "speed-limit-up-enabled", up = "speed-limit-up"
    }
    enum Field: String, CaseIterable, Sendable {
        case honors = "honorsSessionLimits", downEnabled = "speed-limit-down-enabled", down = "speed-limit-down"
        case upEnabled = "speed-limit-up-enabled", up = "speed-limit-up"
        var title: String {
            switch self {
            case .honors: "Honor session speed limits"
            case .downEnabled: "Limit download speed"
            case .down: "Download (kB/s)"
            case .upEnabled: "Limit upload speed"
            case .up: "Upload (kB/s)"
            }
        }
        var isBoolean: Bool { self != .down && self != .up }
    }
    var values: [Field: ServerOptionValue] {
        [.honors: .bool(honorsSessionLimits), .downEnabled: .bool(downEnabled), .down: .int(down),
         .upEnabled: .bool(upEnabled), .up: .int(up)]
    }
}

struct BandwidthGroupEditor: Sendable {
    let baseline: BandwidthGroup?
    var name: String
    var draft: [BandwidthGroup.Field: String]

    init(_ group: BandwidthGroup?) {
        baseline = group
        name = group?.name ?? ""
        let initial = group ?? BandwidthGroup(name: "", honorsSessionLimits: true, downEnabled: false, down: 100,
                                              upEnabled: false, up: 100)
        draft = initial.values.mapValues { value in
            switch value { case .bool(let b): b ? "true" : "false"; case .int(let n): String(n); default: "" }
        }
    }
    var isDirty: Bool {
        if baseline == nil { return !name.isEmpty || draft != Self(nil).draft }
        return draft != Self(baseline).draft
    }
    func validatedName() throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isNewline }), !value.contains("\0") else {
            throw ServerOptionsError(message: "Enter a group name without line breaks.")
        }
        return baseline?.name ?? value
    }
    func patch() throws -> [BandwidthGroup.Field: ServerOptionValue] {
        var result: [BandwidthGroup.Field: ServerOptionValue] = [:]
        for field in BandwidthGroup.Field.allCases {
            let raw = draft[field] ?? ""
            let value: ServerOptionValue
            if field.isBoolean {
                guard raw == "true" || raw == "false" else { throw ServerOptionsError(message: "Choose on or off for \(field.title).") }
                value = .bool(raw == "true")
            } else {
                guard let n = Int(raw.trimmingCharacters(in: .whitespaces)), (0...2_147_483_647).contains(n) else {
                    throw ServerOptionsError(message: "\(field.title): enter a whole number from 0 to 2147483647.")
                }
                value = .int(n)
            }
            if value != baseline?.values[field] { result[field] = value }
        }
        return result
    }
    func checkedPatch(latest: BandwidthGroup?) throws -> [BandwidthGroup.Field: ServerOptionValue] {
        let changes = try patch()
        if baseline == nil {
            guard latest == nil else { throw ServerOptionsError(message: "A group with this name already exists. Reload to edit it.") }
        } else {
            guard let latest else { throw ServerOptionsError(message: "This group is no longer available. Reload before saving.") }
            for (key, desired) in changes where latest.values[key] != baseline?.values[key] && latest.values[key] != desired {
                throw ServerOptionsError(message: "This group changed on the server. Reload before saving.")
            }
            // Do not activate a limit whose unedited companion changed remotely.
            for (toggle, limit) in [(BandwidthGroup.Field.downEnabled, BandwidthGroup.Field.down), (BandwidthGroup.Field.upEnabled, BandwidthGroup.Field.up)] {
                if changes[toggle] == .bool(true), changes[limit] == nil,
                   latest.values[limit] != baseline?.values[limit] {
                    throw ServerOptionsError(message: "A speed limit changed on the server. Reload before enabling it.")
                }
                if changes[limit] != nil, changes[toggle] == nil,
                   latest.values[toggle] != baseline?.values[toggle] {
                    throw ServerOptionsError(message: "A speed limit changed on the server. Reload before saving.")
                }
            }
        }
        return changes.filter { latest?.values[$0.key] != $0.value }
    }
}

@MainActor
final class BandwidthGroupSession {
    let service: any ServerOptionsService
    private(set) var groups: [BandwidthGroup] = []
    var editor = BandwidthGroupEditor(nil)
    private(set) var isBusy = false
    private(set) var needsReload = false
    init(service: any ServerOptionsService) { self.service = service }

    func load() async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let name = editor.baseline?.name ?? (try? editor.validatedName())
        groups = try await service.fetchBandwidthGroups().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        editor = BandwidthGroupEditor(groups.first { $0.name == name } ?? groups.first)
        needsReload = false
    }
    func select(_ group: BandwidthGroup?) {
        guard !isBusy, !needsReload else { return }
        editor = BandwidthGroupEditor(group)
    }
    func save() async throws {
        guard !isBusy, !needsReload else { throw ServerOptionsError(message: "Reload before saving this group again.") }
        let name = try editor.validatedName()
        _ = try editor.patch()
        isBusy = true
        defer { isBusy = false }
        let latest = try await service.fetchBandwidthGroups()
        let changes = try editor.checkedPatch(latest: latest.first { $0.name == name })
        if !changes.isEmpty {
            needsReload = true
            try await service.setBandwidthGroup(name: name, changes: changes)
        }
        let verified = try await service.fetchBandwidthGroups()
        guard let group = verified.first(where: { $0.name == name }), changes.allSatisfy({ group.values[$0.key] == $0.value }) else {
            needsReload = true
            throw ServerOptionsError(message: "The group save could not be verified. Reload before trying again.")
        }
        groups = verified.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        editor = BandwidthGroupEditor(group)
        needsReload = false
    }
}

extension ServerOptionsService {
    func testPeerPort(protocol choice: PeerPortProtocol) async throws -> PeerPortResult {
        guard choice == .automatic else { throw ServerOptionsError(message: "Protocol-specific port tests are unavailable.") }
        return PeerPortResult(isOpen: try await testPeerPort(), ipProtocol: nil)
    }
    func fetchBandwidthGroups() async throws -> [BandwidthGroup] { throw ServerOptionsError(message: "Bandwidth groups are unavailable.") }
    func setBandwidthGroup(name: String, changes: [BandwidthGroup.Field: ServerOptionValue]) async throws {
        throw ServerOptionsError(message: "Bandwidth groups are unavailable.")
    }
}
