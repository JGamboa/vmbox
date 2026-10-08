import XCTest
@testable import VMCore

final class VMLibraryTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
    }

    func testCreateWritesConfigAndSparseDisk() throws {
        let config = VMConfig.defaults(for: .linux, name: "Ubuntu")
        let bundle = try library.create(config)
        XCTAssertEqual(bundle.url.lastPathComponent, "Ubuntu.vmbox")
        XCTAssertEqual(try bundle.readConfig(), config)
        let attributes = try FileManager.default.attributesOfItem(atPath: bundle.diskURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, 40 * .gib)
        let allocated = try bundle.diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? .max
        XCTAssertLessThan(allocated, 1 << 20, "disk.img debe ser sparse")
    }

    func testListReturnsEntriesSortedByName() throws {
        _ = try library.create(.defaults(for: .linux, name: "zeta"))
        _ = try library.create(.defaults(for: .macOS, name: "Alfa"))
        let listing = try library.list()
        XCTAssertEqual(listing.entries.map(\.config.name), ["Alfa", "zeta"])
        XCTAssertEqual(listing.broken, [])
    }

    func testListOnMissingRootIsEmpty() throws {
        XCTAssertEqual(try library.list().entries.count, 0)
    }

    /// Foco de revisión 5: un paquete corrupto no rompe la biblioteca.
    func testCorruptBundleIsReportedNotFatal() throws {
        _ = try library.create(.defaults(for: .linux, name: "buena"))
        let bad = library.root.appending(path: "mala.vmbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{no es json".utf8).write(to: bad.appending(path: "config.json"))
        let listing = try library.list()
        XCTAssertEqual(listing.entries.map(\.config.name), ["buena"])
        XCTAssertEqual(listing.broken.map(\.lastPathComponent), ["mala.vmbox"])
    }

    /// Foco de revisión 5: nombres inválidos.
    func testRejectsInvalidNames() {
        for name in ["", "   ", "a/b", "a:b", ".oculta", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try library.create(.defaults(for: .linux, name: name)), name) { error in
                guard case VMBundleError.invalidName = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRejectsDuplicateNamesCaseInsensitively() throws {
        _ = try library.create(.defaults(for: .linux, name: "Ubuntu"))
        XCTAssertThrowsError(try library.create(.defaults(for: .linux, name: "ubuntu"))) { error in
            XCTAssertEqual(error as? VMBundleError, .alreadyExists("ubuntu"))
        }
    }

    func testTrimsName() throws {
        let bundle = try library.create(.defaults(for: .linux, name: "  Ubuntu  "))
        XCTAssertEqual(try bundle.readConfig().name, "Ubuntu")
    }

    func testWriteConfigPersists() throws {
        let bundle = try library.create(.defaults(for: .linux, name: "u"))
        var config = try bundle.readConfig()
        config.agentControlEnabled = true
        try bundle.writeConfig(config)
        XCTAssertTrue(try bundle.readConfig().agentControlEnabled)
    }

    /// Foco de revisión 4: una creación que falla no deja un paquete a medias.
    func testFailedPopulateRemovesBundle() async throws {
        struct Boom: Error {}
        do {
            _ = try await library.create(.defaults(for: .macOS, name: "mac")) { _ in throw Boom() }
            XCTFail("debió lanzar")
        } catch is Boom {}
        XCTAssertEqual(try library.list().entries.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appending(path: "mac.vmbox").path))
    }
}
