import XCTest
@testable import VMCore

final class SnapshotStoreTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var bundle: VMBundle!
    var store: SnapshotStore!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.diskBytes = 1 << 20
        bundle = try VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory)).create(config)
        try Data("disco-v1".utf8).write(to: bundle.diskURL)
        try Data("nvram-v1".utf8).write(to: bundle.nvramURL)
        store = SnapshotStore(bundle: bundle)
    }

    func testCreateClonesFilesAndWritesInfo() async throws {
        let info = try await store.create(name: "limpio", includesMemory: false)
        XCTAssertEqual(info.name, "limpio")
        XCTAssertFalse(info.includesMemory)
        let dir = store.directory(for: "limpio")
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "disk.img")), Data("disco-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "nvram.bin")), Data("nvram-v1".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "aux.img").path), "solo clona lo que existe")
        XCTAssertEqual(try store.list(), [info])
    }

    func testSnapshotIsIndependentOfLaterWrites() async throws {
        _ = try await store.create(name: "a", includesMemory: false)
        try Data("disco-v2".utf8).write(to: bundle.diskURL)
        XCTAssertEqual(try Data(contentsOf: store.directory(for: "a").appending(path: "disk.img")), Data("disco-v1".utf8))
    }

    func testRestoreReplacesFiles() async throws {
        _ = try await store.create(name: "a", includesMemory: false)
        try Data("disco-v2".utf8).write(to: bundle.diskURL)
        try Data("nvram-v2".utf8).write(to: bundle.nvramURL)
        try store.restoreFiles("a")
        XCTAssertEqual(try Data(contentsOf: bundle.diskURL), Data("disco-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: bundle.nvramURL), Data("nvram-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: store.directory(for: "a").appending(path: "disk.img")), Data("disco-v1".utf8),
                       "restaurar no consume el snapshot")
    }

    func testMemoryStateIsSavedInsideSnapshot() async throws {
        let info = try await store.create(name: "vivo", includesMemory: true) { url in
            try Data("memoria".utf8).write(to: url)
        }
        XCTAssertTrue(info.includesMemory)
        XCTAssertEqual(try Data(contentsOf: store.memoryStateURL(for: "vivo")), Data("memoria".utf8))
    }

    func testFailedSaveLeavesNoSnapshot() async throws {
        struct Boom: Error {}
        do {
            _ = try await store.create(name: "roto", includesMemory: true) { _ in throw Boom() }
            XCTFail("debió lanzar")
        } catch is Boom {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: "roto").path))
        XCTAssertEqual(try store.list(), [])
    }

    func testNameRules() async throws {
        _ = try await store.create(name: "a", includesMemory: false)
        do {
            _ = try await store.create(name: "a", includesMemory: false)
            XCTFail("debió lanzar")
        } catch let error as SnapshotError {
            XCTAssertEqual(error, .alreadyExists("a"))
        }
        do {
            _ = try await store.create(name: "../fuera", includesMemory: false)
            XCTFail("debió lanzar")
        } catch let error as SnapshotError {
            XCTAssertEqual(error, .invalidName("../fuera"))
        }
        XCTAssertThrowsError(try store.restoreFiles("no-existe")) { XCTAssertEqual($0 as? SnapshotError, .notFound("no-existe")) }
    }

    func testListIsSortedByDateAndDeleteRemoves() async throws {
        _ = try await store.create(name: "nuevo", includesMemory: false, date: Date(timeIntervalSince1970: 2000))
        _ = try await store.create(name: "viejo", includesMemory: false, date: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(try store.list().map(\.name), ["viejo", "nuevo"])
        try store.delete("viejo")
        XCTAssertEqual(try store.list().map(\.name), ["nuevo"])
    }

    func testTraversalAndUntrimmedNamesAreRejected() async throws {
        _ = try await store.create(name: "a", includesMemory: false)
        XCTAssertThrowsError(try store.info("../x")) { XCTAssertEqual($0 as? SnapshotError, .invalidName("../x")) }
        XCTAssertThrowsError(try store.delete("../..")) { XCTAssertEqual($0 as? SnapshotError, .invalidName("../..")) }
        XCTAssertThrowsError(try store.restoreFiles("a/../a")) { XCTAssertEqual($0 as? SnapshotError, .invalidName("a/../a")) }
        XCTAssertThrowsError(try store.info(" a")) { XCTAssertEqual($0 as? SnapshotError, .invalidName(" a")) }
        XCTAssertThrowsError(try store.memoryStateURL(for: "../x")) { XCTAssertEqual($0 as? SnapshotError, .invalidName("../x")) }
        XCTAssertEqual(try store.list().map(\.name), ["a"], "ningún nombre inválido borra ni toca snapshots")
    }

    func testDeleteOfTraversalNameLeavesSiblingIntact() async throws {
        // Otro bundle hermano con un snapshot real que un nombre malicioso intentaría borrar.
        let sibling = bundle.url.deletingLastPathComponent()
            .appending(path: "Otro.vmbox/snapshots/x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let marker = sibling.appending(path: "info.json")
        try Data("{}".utf8).write(to: marker)

        XCTAssertThrowsError(try store.delete("../../Otro.vmbox/snapshots/x")) {
            XCTAssertEqual($0 as? SnapshotError, .invalidName("../../Otro.vmbox/snapshots/x"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "el snapshot hermano sigue intacto")
    }
}
