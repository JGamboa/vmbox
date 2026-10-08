import Darwin
import Foundation

public struct SnapshotInfo: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var createdAt: Date
    public var includesMemory: Bool
    public var id: String { name }

    public init(name: String, createdAt: Date, includesMemory: Bool) {
        self.name = name
        self.createdAt = createdAt
        self.includesMemory = includesMemory
    }
}

public enum SnapshotError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case cloneFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "Nombre de snapshot inválido: «\(name)»"
        case .alreadyExists(let name): "Ya existe un snapshot «\(name)»"
        case .notFound(let name): "No existe el snapshot «\(name)»"
        case let .cloneFailed(file, code): "No se pudo clonar \(file): \(String(cString: strerror(code)))"
        }
    }
}

/// Snapshots en `<vm>.vmbox/snapshots/<nombre>/`: clones APFS de los archivos del disco y la NVRAM,
/// `info.json` y, si la VM estaba encendida, `state.vzvmsave`.
public struct SnapshotStore: Sendable {
    public static let clonedFiles = ["disk.img", "nvram.bin", "aux.img"]
    static let infoFile = "info.json"
    static let stateFile = "state.vzvmsave"

    public let bundle: VMBundle

    public init(bundle: VMBundle) { self.bundle = bundle }

    public func directory(for name: String) -> URL {
        bundle.snapshotsURL.appending(path: name, directoryHint: .isDirectory)
    }

    public func memoryStateURL(for name: String) -> URL {
        directory(for: name).appending(path: Self.stateFile)
    }

    public func list() throws -> [SnapshotInfo] {
        guard FileManager.default.fileExists(atPath: bundle.snapshotsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: bundle.snapshotsURL, includingPropertiesForKeys: nil)
            .compactMap { try? Self.decoder.decode(SnapshotInfo.self, from: Data(contentsOf: $0.appending(path: Self.infoFile))) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func info(_ name: String) throws -> SnapshotInfo {
        let url = directory(for: name).appending(path: Self.infoFile)
        guard let data = try? Data(contentsOf: url) else { throw SnapshotError.notFound(name) }
        return try Self.decoder.decode(SnapshotInfo.self, from: data)
    }

    /// Crea el snapshot. Si `includesMemory`, `saveState` debe escribir el estado en la URL recibida
    /// (con la VM pausada). Ante cualquier error, el directorio del snapshot se borra.
    public func create(name rawName: String, includesMemory: Bool, date: Date = .now,
                       saveState: @MainActor (URL) async throws -> Void = { _ in }) async throws -> SnapshotInfo {
        guard let name = try? VMName.validate(rawName) else { throw SnapshotError.invalidName(rawName) }
        let dir = directory(for: name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { throw SnapshotError.alreadyExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if includesMemory { try await saveState(dir.appending(path: Self.stateFile)) }
            for file in Self.clonedFiles where fm.fileExists(atPath: bundle.url.appending(path: file).path) {
                try Self.clone(bundle.url.appending(path: file), to: dir.appending(path: file))
            }
            // info.json guarda la fecha en ISO 8601 (segundos): truncar para que create y list coincidan.
            let created = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
            let info = SnapshotInfo(name: name, createdAt: created, includesMemory: includesMemory)
            try Self.encoder.encode(info).write(to: dir.appending(path: Self.infoFile))
            return info
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Reemplaza los archivos de la VM por los del snapshot (la VM debe estar detenida).
    /// Cada archivo se clona a un temporal y se renombra encima del original (atómico).
    public func restoreFiles(_ name: String) throws {
        _ = try info(name)
        let dir = directory(for: name)
        for file in Self.clonedFiles where FileManager.default.fileExists(atPath: dir.appending(path: file).path) {
            let target = bundle.url.appending(path: file)
            let temporary = bundle.url.appending(path: file + ".restoring")
            try? FileManager.default.removeItem(at: temporary)
            try Self.clone(dir.appending(path: file), to: temporary)
            guard rename(temporary.path, target.path) == 0 else { throw SnapshotError.cloneFailed(file, errno) }
        }
    }

    public func delete(_ name: String) throws {
        _ = try info(name)
        try FileManager.default.removeItem(at: directory(for: name))
    }

    static func clone(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in clonefile(src!, dst!, 0) }
        }
        guard result == 0 else { throw SnapshotError.cloneFailed(source.lastPathComponent, errno) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
