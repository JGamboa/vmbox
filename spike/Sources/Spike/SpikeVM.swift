import Foundation
import Virtualization

@MainActor
enum SpikeVM {
    static let outputDir = URL(filePath: "/tmp/vmbox-spike", directoryHint: .isDirectory)

    /// VM Linux mínima: EFI, ISO como USB, red NAT, GPU virtio 1920×1200, teclado y puntero USB absolutos.
    static func make(isoPath: String) throws -> VZVirtualMachine {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 4
        config.memorySize = 4 << 30
        config.platform = VZGenericPlatformConfiguration()

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try VZEFIVariableStore(
            creatingVariableStoreAt: outputDir.appending(path: "nvram.bin"),
            options: [.allowOverwrite]
        )
        config.bootLoader = bootLoader

        let iso = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: isoPath), readOnly: true)
        config.storageDevices = [VZUSBMassStorageDeviceConfiguration(attachment: iso)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        config.graphicsDevices = [graphics]

        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        try config.validate()
        return VZVirtualMachine(configuration: config)
    }
}
