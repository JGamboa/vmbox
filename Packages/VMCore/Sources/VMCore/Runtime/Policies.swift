import Foundation

public enum StartCheck: Equatable, Sendable { case ok, macOSLimitReached }

public enum StartPolicy {
    /// Límite de Apple para invitados macOS simultáneos en un mismo host.
    public static let maxConcurrentMacOS = 2

    public static func check(starting os: GuestOS, running: [GuestOS]) -> StartCheck {
        guard os == .macOS else { return .ok }
        return running.filter { $0 == .macOS }.count >= maxConcurrentMacOS ? .macOSLimitReached : .ok
    }
}

public enum DiskSpaceError: Error, Equatable, LocalizedError {
    case insufficient(required: UInt64, available: UInt64)

    public var errorDescription: String? {
        switch self {
        case let .insufficient(required, available):
            let f = ByteCountFormatter()
            return "Espacio libre insuficiente: se necesitan \(f.string(fromByteCount: Int64(required))) y hay \(f.string(fromByteCount: Int64(available)))."
        }
    }
}

public enum DiskSpace {
    public static func available(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    public static func ensure(_ required: UInt64, available: UInt64) throws {
        guard available >= required else { throw DiskSpaceError.insufficient(required: required, available: available) }
    }

    /// Margen para descargar el medio e instalar: IPSW ≈18 GB + sistema; ISO ≈4 GB + sistema.
    public static func requiredForCreate(_ os: GuestOS) -> UInt64 {
        os == .macOS ? 50 * .gib : 15 * .gib
    }
}
