import Foundation

public enum GuestOS: String, Codable, Sendable, CaseIterable {
    case macOS = "macos"
    case linux

    public var displayName: String { self == .macOS ? "macOS" : "Ubuntu" }
}

public struct SharedFolder: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool = false) {
        self.path = path
        self.readOnly = readOnly
    }
}

public extension UInt64 {
    static let gib: UInt64 = 1 << 30
}

public enum MACAddress {
    /// MAC unicast administrada localmente (bit 1 del primer byte = 1, bit 0 = 0).
    public static func randomLocallyAdministered() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0b1111_1100) | 0b10
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

public struct VMConfig: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var os: GuestOS
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var sharedFolders: [SharedFolder]
    public var agentControlEnabled: Bool
    public var macAddress: String
    /// ISO de instalación conectada como disco USB (solo Linux). `nil` = sin medio.
    public var installMediaPath: String?

    public init(
        id: UUID = UUID(), name: String, os: GuestOS, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
        sharedFolders: [SharedFolder] = [], agentControlEnabled: Bool = false,
        macAddress: String = MACAddress.randomLocallyAdministered(), installMediaPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.os = os
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.sharedFolders = sharedFolders
        self.agentControlEnabled = agentControlEnabled
        self.macAddress = macAddress
        self.installMediaPath = installMediaPath
    }

    public static func defaults(for os: GuestOS, name: String) -> VMConfig {
        switch os {
        case .macOS: VMConfig(name: name, os: .macOS, cpuCount: 4, memoryBytes: 8 * .gib, diskBytes: 80 * .gib)
        case .linux: VMConfig(name: name, os: .linux, cpuCount: 4, memoryBytes: 4 * .gib, diskBytes: 40 * .gib)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, os, cpuCount, memoryBytes, diskBytes, sharedFolders, agentControlEnabled, macAddress, installMediaPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(GuestOS.self, forKey: .os)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
        diskBytes = try c.decode(UInt64.self, forKey: .diskBytes)
        macAddress = try c.decode(String.self, forKey: .macAddress)
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        agentControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentControlEnabled) ?? false
        installMediaPath = try c.decodeIfPresent(String.self, forKey: .installMediaPath)
    }

    public static func decode(from data: Data) throws -> VMConfig {
        try JSONDecoder().decode(VMConfig.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
