import Foundation
import Virtualization

public enum ConfigurationError: Error, Equatable, LocalizedError {
    case missingFile(String)
    case invalidPlatformData(String)
    case invalidMACAddress(String)
    case sharedFolderMissing(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path): "Falta el archivo \(path)"
        case .invalidPlatformData(let path): "Datos de plataforma inválidos en \(path)"
        case .invalidMACAddress(let mac): "MAC inválida: \(mac)"
        case .sharedFolderMissing(let path): "La carpeta compartida no existe: \(path)"
        }
    }
}

public enum VMConfigurationBuilder {
    public static let displayWidth = 1920
    public static let displayHeight = 1200

    /// Configuración validada, lista para `VZVirtualMachine`. `validate()` exige el entitlement
    /// de virtualización en el proceso, por eso los tests usan `make` y la app usa `build`.
    public static func build(config: VMConfig, bundle: VMBundle, display: DisplayPlan = .fallback) throws -> VZVirtualMachineConfiguration {
        let vz = try make(config: config, bundle: bundle, display: display)
        try vz.validate()
        return vz
    }

    /// Construye la configuración sin validarla.
    public static func make(config: VMConfig, bundle: VMBundle, display: DisplayPlan = .fallback) throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vz.memorySize = min(max(config.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        switch config.os {
        case .linux: try configureLinux(vz, config: config, bundle: bundle, display: display)
        case .macOS: try configureMacOS(vz, bundle: bundle, display: display)
        }
        vz.networkDevices = [try network(config)]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vz.directorySharingDevices = try sharedFolderDevices(config)
        return vz
    }

    public static func sharedFolderDevices(_ config: VMConfig) throws -> [VZDirectorySharingDeviceConfiguration] {
        guard !config.sharedFolders.isEmpty else { return [] }
        var directories: [String: VZSharedDirectory] = [:]
        for (folder, name) in zip(config.sharedFolders, SharedFolderNaming.shareNames(for: config.sharedFolders)) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigurationError.sharedFolderMissing(folder.path)
            }
            directories[name] = VZSharedDirectory(url: URL(filePath: folder.path, directoryHint: .isDirectory), readOnly: folder.readOnly)
        }
        let tag = config.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : SharedFolderNaming.linuxTag
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZMultipleDirectoryShare(directories: directories)
        return [device]
    }

    private static func configureLinux(_ vz: VZVirtualMachineConfiguration, config: VMConfig, bundle: VMBundle, display: DisplayPlan) throws {
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try genericMachineIdentifier(bundle)
        vz.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = FileManager.default.fileExists(atPath: bundle.nvramURL.path)
            ? VZEFIVariableStore(url: bundle.nvramURL)
            : try VZEFIVariableStore(creatingVariableStoreAt: bundle.nvramURL)
        vz.bootLoader = bootLoader

        var storage: [VZStorageDeviceConfiguration] = [try disk(bundle)]
        if let iso = config.installMediaPath {
            guard FileManager.default.fileExists(atPath: iso) else { throw ConfigurationError.missingFile(iso) }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: iso), readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        vz.storageDevices = storage

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: display.widthPixels, heightInPixels: display.heightPixels)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private static func configureMacOS(_ vz: VZVirtualMachineConfiguration, bundle: VMBundle, display: DisplayPlan) throws {
        let platform = VZMacPlatformConfiguration()
        let hardwareData = try read(bundle.hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData), hardwareModel.isSupported else {
            throw ConfigurationError.invalidPlatformData(bundle.hardwareModelURL.path)
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: try read(bundle.machineIdURL)) else {
            throw ConfigurationError.invalidPlatformData(bundle.machineIdURL.path)
        }
        guard FileManager.default.fileExists(atPath: bundle.auxURL.path) else {
            throw ConfigurationError.missingFile(bundle.auxURL.path)
        }
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxURL)
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()
        vz.storageDevices = [try disk(bundle)]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: display.widthPixels, heightInPixels: display.heightPixels, pixelsPerInch: display.pixelsPerInch)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZMacKeyboardConfiguration()]
        vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private static func disk(_ bundle: VMBundle) throws -> VZVirtioBlockDeviceConfiguration {
        VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false))
    }

    private static func network(_ config: VMConfig) throws -> VZVirtioNetworkDeviceConfiguration {
        guard let mac = VZMACAddress(string: config.macAddress) else { throw ConfigurationError.invalidMACAddress(config.macAddress) }
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        device.macAddress = mac
        return device
    }

    private static func genericMachineIdentifier(_ bundle: VMBundle) throws -> VZGenericMachineIdentifier {
        if FileManager.default.fileExists(atPath: bundle.machineIdURL.path) {
            guard let identifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdURL)) else {
                throw ConfigurationError.invalidPlatformData(bundle.machineIdURL.path)
            }
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: bundle.machineIdURL)
        return identifier
    }

    private static func read(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigurationError.missingFile(url.path) }
        return try Data(contentsOf: url)
    }
}
