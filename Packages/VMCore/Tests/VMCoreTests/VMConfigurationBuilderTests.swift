import Virtualization
import XCTest
@testable import VMCore

final class VMConfigurationBuilderTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
    }

    func testLinuxConfigurationCreatesPlatformFiles() throws {
        let config = VMConfig.defaults(for: .linux, name: "u")
        let bundle = try library.create(config)
        let vz = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        XCTAssertEqual(vz.cpuCount, 4)
        XCTAssertEqual(vz.memorySize, 4 * .gib)
        XCTAssertEqual(vz.storageDevices.count, 1)
        XCTAssertTrue(vz.bootLoader is VZEFIBootLoader)
        XCTAssertEqual(vz.socketDevices.count, 1)
        XCTAssertEqual(vz.networkDevices.first?.macAddress.string, config.macAddress)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.nvramURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.machineIdURL.path))
    }

    func testMachineIdentifierIsStableAcrossBuilds() throws {
        let config = VMConfig.defaults(for: .linux, name: "u")
        let bundle = try library.create(config)
        _ = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        let first = try Data(contentsOf: bundle.machineIdURL)
        _ = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        XCTAssertEqual(try Data(contentsOf: bundle.machineIdURL), first)
    }

    func testInstallMediaAddsUSBDevice() throws {
        let iso = try tmp.file("u.iso", contents: Data(count: 1 << 20))
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.installMediaPath = iso.path
        let bundle = try library.create(config)
        let vz = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        XCTAssertEqual(vz.storageDevices.count, 2)
        XCTAssertTrue(vz.storageDevices.last is VZUSBMassStorageDeviceConfiguration)
    }

    func testMissingInstallMediaThrows() throws {
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.installMediaPath = "/no/existe.iso"
        let bundle = try library.create(config)
        XCTAssertThrowsError(try VMConfigurationBuilder.make(config: config, bundle: bundle)) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingFile("/no/existe.iso"))
        }
    }

    func testMacOSWithoutPlatformFilesThrows() throws {
        let config = VMConfig.defaults(for: .macOS, name: "m")
        let bundle = try library.create(config)
        XCTAssertThrowsError(try VMConfigurationBuilder.make(config: config, bundle: bundle)) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingFile(bundle.hardwareModelURL.path))
        }
    }
}
