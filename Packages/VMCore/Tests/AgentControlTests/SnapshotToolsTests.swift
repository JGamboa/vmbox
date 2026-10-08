import AgentControl
import ControlProtocol
import XCTest
import VMCore

@MainActor
final class SnapshotToolsTests: XCTestCase {
    var vm: FakeVM!
    var service: ControlService!

    override func setUp() async throws {
        vm = FakeVM(name: "Ubuntu")
        service = ControlService(directory: FakeDirectory([vm, FakeVM(name: "Privada", agentControlEnabled: false)]))
    }

    func call(_ method: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await service.handle(ControlRequest(id: 1, method: method, params: params))
    }

    func testCreateAndList() async throws {
        let created = try await call("snapshot_create", ["vm": "Ubuntu", "name": "limpio"]).get()
        XCTAssertEqual(created, ["name": "limpio", "created_at": "1970-01-01T00:00:00Z", "includes_memory": true])
        let listed = try await call("snapshot_list", ["vm": "Ubuntu"]).get()
        XCTAssertEqual(listed, ["snapshots": [["name": "limpio", "created_at": "1970-01-01T00:00:00Z", "includes_memory": true]]])
    }

    func testCreateWorksWithStoppedVM() async throws {
        vm.state = .stopped
        let created = try await call("snapshot_create", ["vm": "Ubuntu", "name": "frio"]).get()
        XCTAssertEqual(created["includes_memory"], false)
    }

    func testRestoreRequiresConfirmTrue() async throws {
        _ = try await call("snapshot_create", ["vm": "Ubuntu", "name": "a"]).get()
        let withoutConfirm = await call("snapshot_restore", ["vm": "Ubuntu", "name": "a"])
        let confirmFalse = await call("snapshot_restore", ["vm": "Ubuntu", "name": "a", "confirm": false])
        let confirmString = await call("snapshot_restore", ["vm": "Ubuntu", "name": "a", "confirm": "true"])
        XCTAssertEqual(withoutConfirm.error?.data, .invalidArgument)
        XCTAssertEqual(confirmFalse.error?.data, .invalidArgument)
        XCTAssertEqual(confirmString.error?.data, .invalidArgument)
        XCTAssertEqual(vm.restored, [])

        let restored = try await call("snapshot_restore", ["vm": "Ubuntu", "name": "a", "confirm": true]).get()
        XCTAssertEqual(restored, ["restored": "a", "state": "stopped"])
        XCTAssertEqual(vm.restored, ["a"])
    }

    func testUnknownSnapshotIsInvalidArgument() async {
        let response = await call("snapshot_restore", ["vm": "Ubuntu", "name": "nada", "confirm": true])
        XCTAssertEqual(response.error?.data, .invalidArgument)
        XCTAssertTrue(response.error?.message.contains("nada") ?? false)
    }

    func testBusyAndInvalidStateAreInvalidArgumentWithReadableMessage() async {
        vm.snapshotError = VMInstanceError.busy
        let busy = await call("snapshot_create", ["vm": "Ubuntu", "name": "x"])
        XCTAssertEqual(busy.error?.data, .invalidArgument)
        XCTAssertEqual(busy.error?.message, VMInstanceError.busy.localizedDescription)

        vm.snapshotError = VMInstanceError.invalidStateForSnapshot(.starting)
        let invalid = await call("snapshot_restore", ["vm": "Ubuntu", "name": "x", "confirm": true])
        XCTAssertEqual(invalid.error?.data, .invalidArgument)
        XCTAssertEqual(invalid.error?.message, VMInstanceError.invalidStateForSnapshot(.starting).localizedDescription)
    }

    func testDiskSpaceIsInternalError() async {
        vm.snapshotError = DiskSpaceError.insufficient(required: 10, available: 1)
        let response = await call("snapshot_create", ["vm": "Ubuntu", "name": "x"])
        XCTAssertEqual(response.error?.data, .internalError)
    }

    func testDisabledVMIsRejected() async {
        for method in ["snapshot_create", "snapshot_list", "snapshot_restore"] {
            let response = await call(method, ["vm": "Privada", "name": "x", "confirm": true])
            XCTAssertEqual(response.error?.data, .agentControlDisabled, method)
        }
    }
}
