import ControlProtocol
import MCP
import XCTest
@testable import MCPBridge

final class BridgeTests: XCTestCase {
    func params(_ name: String, _ arguments: [String: Value] = [:]) -> CallTool.Parameters {
        CallTool.Parameters(name: name, arguments: arguments)
    }

    func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    func testCatalogMatchesSpec() {
        XCTAssertEqual(ToolCatalog.specs.map(\.name),
                       ["list_vms", "start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key",
                        "snapshot_create", "snapshot_list", "snapshot_restore",
                        "run_command", "read_file", "write_file", "clipboard_get", "clipboard_set"])
        for spec in ToolCatalog.specs where spec.name != "list_vms" {
            XCTAssertTrue(spec.required.contains("vm"), spec.name)
            XCTAssertFalse(spec.description.isEmpty)
        }
        XCTAssertTrue(ToolCatalog.spec(named: "snapshot_restore")!.required.contains("confirm"))
    }

    func testScreenshotBecomesImagePlusText() async {
        let fake = FakeControl([.success(["image_png_base64": "iVBORw0KGgo=", "width": 1280, "height": 800, "scale": 1])])
        let result = await Bridge(client: fake, launcher: FakeLauncher()).handle(params("screenshot", ["vm": "u"]))
        XCTAssertEqual(result.isError, false)
        guard case .image(let data, let mime, _, _) = result.content.first else { return XCTFail("\(result.content)") }
        XCTAssertEqual(data, "iVBORw0KGgo=")
        XCTAssertEqual(mime, "image/png")
        XCTAssertTrue(text(result).contains("\"width\" : 1280"))
        XCTAssertFalse(text(result).contains("iVBOR"))
    }

    func testArgumentsAreForwardedUnchanged() async {
        let fake = FakeControl([.success(["ok": true])])
        _ = await Bridge(client: fake, launcher: FakeLauncher())
            .handle(params("click", ["vm": "u", "x": 10.5, "y": 3, "button": "right"]))
        let call = await fake.calls.first
        XCTAssertEqual(call?.method, "click")
        XCTAssertEqual(call?.params, ["vm": "u", "x": 10.5, "y": 3, "button": "right"])
    }

    func testControlErrorBecomesIsError() async {
        let fake = FakeControl([.failure(ControlError(code: .agentControlDisabled, message: "apagado"))])
        let result = await Bridge(client: fake, launcher: FakeLauncher()).handle(params("click", ["vm": "u", "x": 1, "y": 1]))
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(text(result), "agent_control_disabled: apagado")
    }

    /// Foco de revisión 3: app no corriendo → se lanza y se reintenta una vez.
    func testAppUnavailableLaunchesAndRetriesOnce() async {
        let fake = FakeControl([.failure(ControlError(code: .appUnavailable, message: "x")), .success(["vms": []])])
        let launcher = FakeLauncher()
        let result = await Bridge(client: fake, launcher: launcher).handle(params("list_vms"))
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(launcher.launches.value, 1)
        let count = await fake.calls.count
        XCTAssertEqual(count, 2)
    }

    func testLaunchFailureIsAppUnavailable() async {
        let fake = FakeControl([.failure(ControlError(code: .appUnavailable, message: "x"))])
        let result = await Bridge(client: fake, launcher: FakeLauncher(succeeds: false)).handle(params("list_vms"))
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).hasPrefix("app_unavailable"))
    }

    func testUnknownTool() async {
        let result = await Bridge(client: FakeControl([]), launcher: FakeLauncher()).handle(params("format_disk"))
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).hasPrefix("invalid_argument"))
    }

    func testTimeouts() async {
        let fake = FakeControl([.success(["state": "running"]), .success(["ok": true])])
        let bridge = Bridge(client: fake, launcher: FakeLauncher())
        _ = await bridge.handle(params("start_vm", ["vm": "u"]))
        _ = await bridge.handle(params("type_text", ["vm": "u", "text": .string(String(repeating: "a", count: 1000))]))
        let timeouts = await fake.calls.map(\.timeout)
        XCTAssertEqual(timeouts, [120, 80])
    }

    /// Protocolo de punta a punta: cliente MCP ↔ vmbox-mcp (Bridge) ↔ socket simulado.
    func testEndToEndOverMCPAndSocket() async throws {
        let path = "/tmp/vmbox-bridge-\(UUID().uuidString.prefix(8)).sock"
        let controlServer = ControlServer(path: path) { request in
            switch request.method {
            case "screenshot":
                .success(id: request.id, result: ["image_png_base64": "iVBORw0KGgo=", "width": 1280, "height": 800, "scale": 1])
            default:
                .failure(id: request.id, error: ControlError(code: .agentControlDisabled, message: "apagado"))
            }
        }
        try controlServer.start()
        defer { controlServer.stop() }

        let server = Server(name: "vmbox", version: "test", capabilities: .init(tools: .init(listChanged: false)))
        await Bridge(client: ControlClient(path: path), launcher: FakeLauncher(succeeds: false)).register(on: server)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "0")
        try await client.connect(transport: clientTransport)

        let (tools, _) = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ToolCatalog.specs.map(\.name))

        let (content, isError) = try await client.callTool(name: "screenshot", arguments: ["vm": "u"])
        XCTAssertEqual(isError, false)
        guard case .image = content.first else { return XCTFail("\(content)") }

        let (errorContent, errorFlag) = try await client.callTool(name: "click", arguments: ["vm": "u", "x": 1, "y": 1])
        XCTAssertEqual(errorFlag, true)
        guard case .text(let message, _, _) = errorContent.first else { return XCTFail("\(errorContent)") }
        XCTAssertTrue(message.hasPrefix("agent_control_disabled"))
        await server.stop()
    }
}
