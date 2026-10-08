import Foundation

public struct LinuxVMCreator: Sendable {
    public let library: VMLibrary
    public let downloader: Downloader
    public let cacheDir: URL
    public let session: URLSession
    public let requiredFreeBytes: UInt64

    public init(library: VMLibrary, downloader: Downloader, cacheDir: URL, session: URLSession = .shared,
                requiredFreeBytes: UInt64 = DiskSpace.requiredForCreate(.linux)) {
        self.library = library
        self.downloader = downloader
        self.cacheDir = cacheDir
        self.session = session
        self.requiredFreeBytes = requiredFreeBytes
    }

    /// Crea el paquete con el ISO conectado como USB; el usuario completa el instalador en la ventana de la VM.
    public func create(config: VMConfig, localISO: URL?, onPhase: @escaping @Sendable (CreationPhase) -> Void) async throws -> VMBundle {
        onPhase(.preparing)
        try library.ensureRoot()
        try DiskSpace.ensure(requiredFreeBytes, available: DiskSpace.available(at: library.root))
        _ = try VMName.validate(config.name)

        let iso: URL
        if let localISO {
            iso = localISO
        } else {
            let (data, _) = try await session.data(from: UbuntuRelease.sha256SumsURL)
            guard let sha = UbuntuRelease.parseSHA256(sums: String(decoding: data, as: UTF8.self), fileName: UbuntuRelease.isoFileName) else {
                throw CreationError.checksumUnavailable
            }
            let request = DownloadRequest(url: UbuntuRelease.isoURL, destination: cacheDir.appending(path: UbuntuRelease.isoFileName), expectedSHA256: sha)
            iso = try await downloader.download(request) { onPhase(.downloading($0)) }
        }

        var withMedia = config
        withMedia.installMediaPath = iso.path
        let bundle = try library.create(withMedia)
        onPhase(.finished)
        return bundle
    }
}
