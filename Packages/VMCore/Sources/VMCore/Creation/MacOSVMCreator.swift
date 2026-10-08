import Foundation
import Virtualization

@MainActor
public final class MacOSVMCreator {
    let library: VMLibrary
    let downloader: Downloader
    let cacheDir: URL

    public init(library: VMLibrary, downloader: Downloader, cacheDir: URL) {
        self.library = library
        self.downloader = downloader
        self.cacheDir = cacheDir
    }

    /// Descarga (o usa) un IPSW, crea plataforma + almacenamiento auxiliar e instala macOS.
    /// Si algo falla después de crear el paquete, el paquete se borra.
    public func create(config: VMConfig, localIPSW: URL?, onPhase: @escaping @MainActor @Sendable (CreationPhase) -> Void) async throws -> VMBundle {
        onPhase(.preparing)
        try library.ensureRoot()
        try DiskSpace.ensure(DiskSpace.requiredForCreate(.macOS), available: DiskSpace.available(at: library.root))
        _ = try VMName.validate(config.name)

        let ipsw: URL
        if let localIPSW {
            ipsw = localIPSW
        } else {
            let latest = try await VZMacOSRestoreImage.latestSupported
            let request = DownloadRequest(url: latest.url, destination: cacheDir.appending(path: latest.url.lastPathComponent), expectedSHA256: nil)
            ipsw = try await downloader.download(request) { fraction in
                Task { @MainActor in onPhase(.downloading(fraction)) }
            }
        }

        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw CreationError.unsupportedRestoreImage
        }
        var adjusted = config
        adjusted.cpuCount = max(adjusted.cpuCount, requirements.minimumSupportedCPUCount)
        adjusted.memoryBytes = max(adjusted.memoryBytes, requirements.minimumSupportedMemorySize)

        let bundle = try await library.create(adjusted) { bundle in
            try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdURL)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxURL, hardwareModel: requirements.hardwareModel, options: [])
            let vm = VZVirtualMachine(configuration: try VMConfigurationBuilder.build(config: adjusted, bundle: bundle))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onPhase(.installing(fraction)) }
            }
            defer { observation.invalidate() }
            try await installer.install()
        }
        onPhase(.finished)
        return bundle
    }
}
