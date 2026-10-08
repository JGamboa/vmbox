import Foundation

public enum VMBundleError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "Nombre de VM inválido: «\(name)». Usa 1–64 caracteres, sin «/» ni «:» y sin empezar con «.»."
        case .alreadyExists(let name): "Ya existe una VM llamada «\(name)»."
        }
    }
}

public enum VMName {
    public static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw VMBundleError.invalidName(raw)
        }
        return name
    }
}

public struct VMBundle: Sendable, Equatable {
    public static let fileExtension = "vmbox"
    public let url: URL

    public init(url: URL) { self.url = url }

    public var configURL: URL { url.appending(path: "config.json") }
    public var diskURL: URL { url.appending(path: "disk.img") }
    public var auxURL: URL { url.appending(path: "aux.img") }
    public var hardwareModelURL: URL { url.appending(path: "hardware-model.bin") }
    public var machineIdURL: URL { url.appending(path: "machine-id.bin") }
    public var nvramURL: URL { url.appending(path: "nvram.bin") }
    public var snapshotsURL: URL { url.appending(path: "snapshots", directoryHint: .isDirectory) }

    public func readConfig() throws -> VMConfig {
        try VMConfig.decode(from: Data(contentsOf: configURL))
    }

    public func writeConfig(_ config: VMConfig) throws {
        try config.encoded().write(to: configURL, options: .atomic)
    }

    /// Bytes realmente ocupados en disco por todo el paquete (archivos sparse cuentan lo usado).
    public func allocatedBytes() -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            total += UInt64((try? file.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
