import Virtualization
import XCTest
@testable import VMCore

final class SharedFoldersTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
    }

    func makeFolder(_ path: String) throws -> URL {
        let url = tmp.url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testShareNamesAreUnique() {
        let folders = [SharedFolder(path: "/a/Proyectos"), SharedFolder(path: "/b/Proyectos"), SharedFolder(path: "/c/Docs")]
        XCTAssertEqual(SharedFolderNaming.shareNames(for: folders), ["Proyectos", "Proyectos-2", "Docs"])
    }

    func testNoFoldersNoDevice() throws {
        let config = VMConfig.defaults(for: .linux, name: "u")
        let vz = try VMConfigurationBuilder.make(config: config, bundle: library.create(config))
        XCTAssertTrue(vz.directorySharingDevices.isEmpty)
    }

    func testLinuxUsesVMBoxTagAndAllFolders() throws {
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.sharedFolders = [SharedFolder(path: try makeFolder("uno/Proyectos").path, readOnly: true),
                                SharedFolder(path: try makeFolder("dos/Proyectos").path)]
        let vz = try VMConfigurationBuilder.make(config: config, bundle: library.create(config))
        let device = try XCTUnwrap(vz.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)
        XCTAssertEqual(device.tag, "vmbox")
        let share = try XCTUnwrap(device.share as? VZMultipleDirectoryShare)
        XCTAssertEqual(Set(share.directories.keys), ["Proyectos", "Proyectos-2"])
        XCTAssertEqual(share.directories["Proyectos"]?.isReadOnly, true)
    }

    func testMacOSUsesAutomountTag() throws {
        var config = VMConfig.defaults(for: .macOS, name: "m")
        config.sharedFolders = [SharedFolder(path: try makeFolder("x").path)]
        let device = try XCTUnwrap(VMConfigurationBuilder.sharedFolderDevices(config).first as? VZVirtioFileSystemDeviceConfiguration)
        XCTAssertEqual(device.tag, VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
    }

    func testMissingFolderFailsClearly() throws {
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.sharedFolders = [SharedFolder(path: "/no/existe")]
        XCTAssertThrowsError(try VMConfigurationBuilder.make(config: config, bundle: library.create(config))) { error in
            XCTAssertEqual(error as? ConfigurationError, .sharedFolderMissing("/no/existe"))
        }
    }

    func testGuestHints() {
        XCTAssertTrue(SharedFolderNaming.guestHint(for: .linux).contains("mount -t virtiofs vmbox /mnt/vmbox"))
        XCTAssertTrue(SharedFolderNaming.guestHint(for: .macOS).contains("/Volumes/My Shared Files"))
    }
}
