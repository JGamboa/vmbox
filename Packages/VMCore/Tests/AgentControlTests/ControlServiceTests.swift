import AgentControl
import ControlProtocol
import CoreGraphics
import XCTest
import VMCore

@MainActor
final class ControlServiceTests: XCTestCase {
    var ubuntu: FakeVM!
    var locked: FakeVM!
    var service: ControlService!
    var activity: [UUID] = []

    override func setUp() async throws {
        ubuntu = FakeVM(name: "Ubuntu")
        locked = FakeVM(name: "Privada", agentControlEnabled: false)
        service = ControlService(directory: FakeDirectory([ubuntu, locked]))
        activity = []
        service.onAgentActivity = { [unowned self] in self.activity.append($0) }
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await service.handle(ControlRequest(id: 1, method: method, params: params))
    }

    /// Resultado de una llamada que debe tener éxito.
    func ok(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await call(method, params).get()
    }

    /// Código de error de una llamada que debe fallar.
    func failure(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlErrorCode? {
        await call(method, params).error?.data
    }

    func testListIncludesDisabledVMs() async throws {
        let result = try await ok("list_vms")
        guard case .array(let vms)? = result["vms"] else { return XCTFail("\(result)") }
        XCTAssertEqual(vms.count, 2)
        XCTAssertEqual(vms[1], ["name": "Privada", "os": "linux", "state": "running", "agentControlEnabled": false])
    }

    func testUnknownVM() async {
        let code = await failure("screenshot", ["vm": "nada"])
        XCTAssertEqual(code, .vmNotFound)
    }

    func testMatchesNameCaseInsensitively() async throws {
        _ = try await ok("click", ["vm": "ubuntu", "x": 1, "y": 1])
        XCTAssertEqual(ubuntu.performed.count, 1)
    }

    func testDisabledVMIsRejectedForEveryToolButList() async {
        for method in ["start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key"] {
            let code = await failure(method, ["vm": "Privada"])
            XCTAssertEqual(code, .agentControlDisabled, method)
        }
        XCTAssertTrue(locked.performed.isEmpty)
    }

    func testStoppedVMIsNotRunning() async {
        ubuntu.state = .stopped
        let screenshot = await failure("screenshot", ["vm": "Ubuntu"])
        let click = await failure("click", ["vm": "Ubuntu", "x": 1, "y": 1])
        XCTAssertEqual(screenshot, .vmNotRunning)
        XCTAssertEqual(click, .vmNotRunning)
    }

    func testStartAndStop() async throws {
        ubuntu.state = .stopped
        let started = try await ok("start_vm", ["vm": "Ubuntu"])
        XCTAssertEqual(started, ["state": "running"])
        XCTAssertEqual(ubuntu.startCount, 1)
        _ = try await ok("start_vm", ["vm": "Ubuntu"])
        XCTAssertEqual(ubuntu.startCount, 1, "start_vm es idempotente")
        let stopped = try await ok("stop_vm", ["vm": "Ubuntu", "force": true])
        XCTAssertEqual(stopped, ["state": "stopped"])
        XCTAssertEqual(ubuntu.stopForces, [true])
    }

    func testScreenshotReturnsPNGAtMost1280Wide() async throws {
        let result = try await ok("screenshot", ["vm": "Ubuntu"])
        XCTAssertEqual(result["width"], 1280)
        XCTAssertEqual(result["height"], 800)
        XCTAssertEqual(result["scale"], 1)
        let png = try XCTUnwrap(result["image_png_base64"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testZeroSizedViewIsInternalError() async throws {
        ubuntu.metrics = ViewMetrics(width: 0, height: 0, backingScale: 2, isFlipped: false)
        let shot = await failure("screenshot", ["vm": "Ubuntu"])
        let click = await failure("click", ["vm": "Ubuntu", "x": 1, "y": 1])
        XCTAssertEqual(shot, .internalError)
        XCTAssertEqual(click, .internalError)
        XCTAssertTrue(ubuntu.performed.isEmpty)
    }

    func testClickMapsCoordinatesAndReportsActivity() async throws {
        _ = try await ok("screenshot", ["vm": "Ubuntu"])
        _ = try await ok("click", ["vm": "Ubuntu", "x": 100, "y": 50, "button": "right", "count": 2])
        XCTAssertEqual(ubuntu.performed, [.click(at: CGPoint(x: 100, y: 750), button: .right, count: 2)])
        XCTAssertEqual(activity, [ubuntu.id])
    }

    /// Foco de revisión 2: ventana redimensionada después de la captura.
    func testClickAfterResizeKeepsRelativePosition() async throws {
        _ = try await ok("screenshot", ["vm": "Ubuntu"])
        ubuntu.metrics = ViewMetrics(width: 640, height: 400, backingScale: 2, isFlipped: false)
        _ = try await ok("click", ["vm": "Ubuntu", "x": 100, "y": 50])
        XCTAssertEqual(ubuntu.performed, [.click(at: CGPoint(x: 50, y: 375), button: .left, count: 1)])
    }

    /// Foco de revisión 2: fuera de la última captura → invalid_argument sin clic.
    func testOutOfBoundsClickIsRejected() async throws {
        _ = try await ok("screenshot", ["vm": "Ubuntu"])
        let outside = await failure("click", ["vm": "Ubuntu", "x": 5000, "y": 10])
        let tripleClick = await failure("click", ["vm": "Ubuntu", "x": 10, "y": 10, "count": 3])
        XCTAssertEqual(outside, .invalidArgument)
        XCTAssertEqual(tripleClick, .invalidArgument)
        XCTAssertTrue(ubuntu.performed.isEmpty)
    }

    func testDragAndScroll() async throws {
        _ = try await ok("drag", ["vm": "Ubuntu", "from_x": 0, "from_y": 0, "to_x": 1279, "to_y": 799])
        _ = try await ok("scroll", ["vm": "Ubuntu", "x": 640, "y": 400, "dx": 0, "dy": 300])
        XCTAssertEqual(ubuntu.performed, [
            .drag(from: CGPoint(x: 0, y: 800), to: CGPoint(x: 1279, y: 1)),
            .scroll(at: CGPoint(x: 640, y: 400), dx: 0, dy: 300),
        ])
    }

    func testTypeTextAndKey() async throws {
        _ = try await ok("type_text", ["vm": "Ubuntu", "text": "ls\n"])
        _ = try await ok("key", ["vm": "Ubuntu", "combo": "cmd+space"])
        XCTAssertEqual(ubuntu.performed, [
            .keys([KeyStroke(keyCode: 37, modifiers: [], characters: "l"),
                   KeyStroke(keyCode: 1, modifiers: [], characters: "s"),
                   KeyStroke(keyCode: 36, modifiers: [], characters: "\r")]),
            .keys([KeyStroke(keyCode: 49, modifiers: .command, characters: " ")]),
        ])
    }

    /// Foco de revisión 1: no ASCII → invalid_argument y nada tecleado.
    func testNonASCIITextTypesNothing() async {
        let response = await call("type_text", ["vm": "Ubuntu", "text": "hola ñandú"])
        XCTAssertEqual(response.error?.data, .invalidArgument)
        XCTAssertTrue(response.error?.message.contains("ñú") ?? false)
        XCTAssertTrue(ubuntu.performed.isEmpty)
    }

    func testMissingAndMistypedParameters() async {
        let missing = await call("click", ["vm": "Ubuntu", "x": 1])
        XCTAssertEqual(missing.error?.data, .invalidArgument)
        XCTAssertTrue(missing.error?.message.contains("«y»") ?? false)
        let mistyped = await failure("click", ["vm": "Ubuntu", "x": "uno", "y": 1])
        let badCombo = await failure("key", ["vm": "Ubuntu", "combo": "ctrl+foo"])
        let unknownMethod = await failure("no_existe")
        let missingVM = await failure("screenshot")
        XCTAssertEqual(mistyped, .invalidArgument)
        XCTAssertEqual(badCombo, .invalidArgument)
        XCTAssertEqual(unknownMethod, .invalidArgument)
        XCTAssertEqual(missingVM, .invalidArgument)
    }
}
