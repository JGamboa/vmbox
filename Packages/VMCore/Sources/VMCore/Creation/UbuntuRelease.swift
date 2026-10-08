import Foundation

public enum CreationPhase: Equatable, Sendable {
    case preparing
    case downloading(Double)
    case installing(Double)
    case finished
}

public enum CreationError: Error, Equatable, LocalizedError {
    case checksumUnavailable
    case unsupportedRestoreImage

    public var errorDescription: String? {
        switch self {
        case .checksumUnavailable: "No se encontró el SHA256 publicado del ISO de Ubuntu."
        case .unsupportedRestoreImage: "Este Mac no soporta la imagen de restauración de macOS elegida."
        }
    }
}

/// Última LTS de Ubuntu para arm64 (actualizar `version` y `directory` cuando salga una nueva).
public enum UbuntuRelease {
    public static let version = "26.04.1"
    public static let directory = URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/")!
    public static var isoFileName: String { "ubuntu-\(version)-desktop-arm64.iso" }
    public static var isoURL: URL { directory.appending(path: isoFileName) }
    public static var sha256SumsURL: URL { directory.appending(path: "SHA256SUMS") }

    /// Formato de cada línea: `<hash> *<archivo>`.
    public static func parseSHA256(sums: String, fileName: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[1].hasPrefix("*") ? parts[1].dropFirst() : parts[1]
            if name == fileName { return String(parts[0]).lowercased() }
        }
        return nil
    }
}
