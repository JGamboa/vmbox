import AgentControl
import ControlProtocol
import XCTest
import VMCore

@MainActor
final class RevocationTests: XCTestCase {
    var vm: FakeVM!
    var other: FakeVM!
    var service: ControlService!

    override func setUp() async throws {
        vm = FakeVM(name: "Ubuntu")
        other = FakeVM(name: "Otra")
        service = ControlService(directory: FakeDirectory([vm, other]))
    }

    func call(_ method: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await service.handle(ControlRequest(id: 1, method: method, params: params))
    }

    func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = condition()
        XCTAssertTrue(satisfied)
    }

    func testRevokeAnswersInFlightCallImmediatelyAndCancelsItsWork() async throws {
        vm.guestDelay = .seconds(60)
        let started = ContinuousClock.now
        let pending = Task { await self.call("run_command", ["vm": "Ubuntu", "command": "sleep 3600", "timeout_s": 3600]) }
        try await waitUntil { self.service.inFlightCount(self.vm.id) == 1 }

        vm.agentControlEnabled = false
        service.revoke(vm.id)

        let response = await pending.value
        XCTAssertEqual(response.error?.data, .agentControlDisabled)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        try await waitUntil { self.vm.guestCancelled }
        XCTAssertEqual(service.inFlightCount(vm.id), 0)
    }

    func testRevokeOnlyAffectsThatVM() async throws {
        vm.guestDelay = .milliseconds(300)
        other.guestDelay = .milliseconds(300)
        let mine = Task { await self.call("run_command", ["vm": "Ubuntu", "command": "true"]) }
        let theirs = Task { await self.call("run_command", ["vm": "Otra", "command": "true"]) }
        try await waitUntil { self.service.inFlightCount(self.vm.id) == 1 && self.service.inFlightCount(self.other.id) == 1 }

        vm.agentControlEnabled = false
        service.revoke(vm.id)

        let mineResponse = await mine.value
        let theirsResponse = await theirs.value
        XCTAssertEqual(mineResponse.error?.data, .agentControlDisabled)
        XCTAssertNil(theirsResponse.error)
        XCTAssertFalse(other.guestCancelled)
    }

    func testResultIsWithheldIfControlWasTurnedOffDuringTheCall() async {
        vm.onGuestCall = { [unowned vm] in vm?.agentControlEnabled = false }
        let response = await call("read_file", ["vm": "Ubuntu", "path": "/etc/hostname"])
        XCTAssertEqual(response.error?.data, .agentControlDisabled)
    }

    func testNewCallsAfterRevokeAreRejectedBeforeReachingTheGuest() async {
        vm.agentControlEnabled = false
        service.revoke(vm.id)
        let response = await call("run_command", ["vm": "Ubuntu", "command": "true"])
        XCTAssertEqual(response.error?.data, .agentControlDisabled)
        XCTAssertTrue(vm.guestCalls.isEmpty)
    }

    func testCompletedCallsAreNotTracked() async throws {
        _ = try await call("clipboard_get", ["vm": "Ubuntu"]).get()
        XCTAssertEqual(service.inFlightCount(vm.id), 0)
        service.revoke(vm.id) // sin llamadas en curso: no hace nada
    }
}
