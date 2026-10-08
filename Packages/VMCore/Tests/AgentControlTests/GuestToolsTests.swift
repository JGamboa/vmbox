import AgentControl
import ControlProtocol
import XCTest
import VMCore

@MainActor
final class GuestToolsTests: XCTestCase {
    var vm: FakeVM!
    var service: ControlService!

    override func setUp() async throws {
        vm = FakeVM(name: "Ubuntu")
        service = ControlService(directory: FakeDirectory([vm, FakeVM(name: "Privada", agentControlEnabled: false)]))
    }

    func call(_ method: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await service.handle(ControlRequest(id: 1, method: method, params: params))
    }

    func testRunCommandIsForwardedWithoutVMAndWithTimeout() async throws {
        vm.guestReply = ["stdout": "Linux\n", "exit_code": 0]
        let result = try await call("run_command", ["vm": "Ubuntu", "command": "uname", "timeout_s": 100, "as_root": true]).get()
        XCTAssertEqual(result, ["stdout": "Linux\n", "exit_code": 0])
        XCTAssertEqual(vm.guestCalls.first?.method, "run_command")
        XCTAssertEqual(vm.guestCalls.first?.params, ["command": "uname", "timeout_s": 100, "as_root": true])
        XCTAssertEqual(vm.guestCalls.first?.timeout, 110)
    }

    func testDefaultTimeoutIs60PlusMargin() async throws {
        _ = try await call("run_command", ["vm": "Ubuntu", "command": "true"]).get()
        XCTAssertEqual(vm.guestCalls.first?.timeout, 70)
    }

    func testFileAndClipboardToolsAreForwarded() async throws {
        _ = try await call("read_file", ["vm": "Ubuntu", "path": "/etc/hostname"]).get()
        _ = try await call("write_file", ["vm": "Ubuntu", "path": "/tmp/a", "content": "x"]).get()
        _ = try await call("clipboard_get", ["vm": "Ubuntu"]).get()
        _ = try await call("clipboard_set", ["vm": "Ubuntu", "text": "hola"]).get()
        XCTAssertEqual(vm.guestCalls.map(\.method), ["read_file", "write_file", "clipboard_get", "clipboard_set"])
        XCTAssertEqual(vm.guestCalls.map(\.timeout), [30, 30, 30, 30])
    }

    func testValidationHappensBeforeContactingGuest() async {
        let cases: [(String, [String: JSONValue])] = [
            ("run_command", ["vm": "Ubuntu"]),
            ("run_command", ["vm": "Ubuntu", "command": "  "]),
            ("run_command", ["vm": "Ubuntu", "command": "ls", "timeout_s": 0]),
            ("run_command", ["vm": "Ubuntu", "command": "ls", "timeout_s": 7200]),
            ("read_file", ["vm": "Ubuntu", "path": "relativa"]),
            ("write_file", ["vm": "Ubuntu", "path": "/tmp/a"]),
            ("clipboard_set", ["vm": "Ubuntu"]),
        ]
        for (method, params) in cases {
            let response = await call(method, params)
            XCTAssertEqual(response.error?.data, .invalidArgument, "\(method) \(params)")
        }
        XCTAssertTrue(vm.guestCalls.isEmpty)
    }

    func testPermissionsAndState() async {
        let disabled = await call("run_command", ["vm": "Privada", "command": "ls"])
        XCTAssertEqual(disabled.error?.data, .agentControlDisabled)
        vm.state = .stopped
        let stopped = await call("run_command", ["vm": "Ubuntu", "command": "ls"])
        XCTAssertEqual(stopped.error?.data, .vmNotRunning)
        XCTAssertTrue(vm.guestCalls.isEmpty)
    }
}
