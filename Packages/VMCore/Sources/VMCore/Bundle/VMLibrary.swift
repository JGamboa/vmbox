import Foundation

public struct VMEntry: Sendable, Identifiable {
    public var bundle: VMBundle
    public var config: VMConfig
    public var diskUsageBytes: UInt64
    public var id: UUID { config.id }
}

public struct VMLibraryListing: Sendable {
    public var entries: [VMEntry]
    public var broken: [URL]
}

public struct VMLibrary: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL { VMBoxPaths.vms }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func list() throws -> VMLibraryListing {
        guard FileManager.default.fileExists(atPath: root.path) else { return VMLibraryListing(entries: [], broken: []) }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == VMBundle.fileExtension }
        var entries: [VMEntry] = []
        var broken: [URL] = []
        for url in urls {
            let bundle = VMBundle(url: url)
            if let config = try? bundle.readConfig() {
                entries.append(VMEntry(bundle: bundle, config: config, diskUsageBytes: bundle.allocatedBytes()))
            } else {
                broken.append(url)
            }
        }
        entries.sort {
            let order = $0.config.name.localizedStandardCompare($1.config.name)
            return order == .orderedSame ? $0.bundle.url.deletingPathExtension().path < $1.bundle.url.deletingPathExtension().path : order == .orderedAscending
        }
        // Un paquete copiado en Finder repite el id: se conserva el primero y los demás se informan como ilegibles.
        var seen = Set<UUID>()
        entries = entries.filter { entry in
            if seen.insert(entry.config.id).inserted { return true }
            broken.append(entry.bundle.url)
            return false
        }
        broken.sort { $0.lastPathComponent < $1.lastPathComponent }
        return VMLibraryListing(entries: entries, broken: broken)
    }

    /// Crea `<nombre>.vmbox` con `config.json` y `disk.img` sparse del tamaño configurado.
    public func create(_ config: VMConfig) throws -> VMBundle {
        var config = config
        config.name = try VMName.validate(config.name)
        try ensureRoot()
        let existing = try list()
        let taken = existing.entries.map { $0.config.name.lowercased() }
            + existing.broken.map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        guard !taken.contains(config.name.lowercased()) else { throw VMBundleError.alreadyExists(config.name) }

        let bundle = VMBundle(url: root.appending(path: "\(config.name).\(VMBundle.fileExtension)", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: false)
        do {
            try bundle.writeConfig(config)
            FileManager.default.createFile(atPath: bundle.diskURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: bundle.diskURL)
            try handle.truncate(atOffset: config.diskBytes)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        return bundle
    }

    /// Crea el paquete y ejecuta `populate` en el hilo principal (Virtualization lo exige);
    /// si `populate` falla, el paquete se borra.
    public func create(_ config: VMConfig, populate: @MainActor (VMBundle) async throws -> Void) async throws -> VMBundle {
        let bundle = try create(config)
        do {
            try await populate(bundle)
        } catch {
            try? remove(bundle)
            throw error
        }
        return bundle
    }

    public func remove(_ bundle: VMBundle) throws {
        try FileManager.default.removeItem(at: bundle.url)
    }
}
