import Darwin
import XCTest
@testable import ControlProtocol

final class ControlServerTests: XCTestCase {
    var path: String!
    var server: ControlServer?

    override func setUp() { path = makeSocketPath() }
    override func tearDown() { server?.stop() }

    func startServer(_ handler: @escaping ControlServer.Handler) throws {
        let server = ControlServer(path: path, handler: handler)
        try server.start()
        self.server = server
    }

    func testRoundTrip() async throws {
        try startServer { request in .success(id: request.id, result: ["echo": .string(request.method)]) }
        let result = try await ControlClient(path: path).call(method: "list_vms", params: [:], timeout: 5)
        XCTAssertEqual(result, ["echo": "list_vms"])
    }

    func testErrorPropagatesAsControlError() async throws {
        try startServer { request in .failure(id: request.id, error: ControlError(code: .vmNotRunning, message: "apagada")) }
        do {
            _ = try await ControlClient(path: path).call(method: "screenshot", params: ["vm": "u"], timeout: 5)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error, ControlError(code: .vmNotRunning, message: "apagada"))
        }
    }

    func testTimeout() async throws {
        try startServer { request in
            try? await Task.sleep(for: .seconds(2))
            return .success(id: request.id, result: nil)
        }
        do {
            _ = try await ControlClient(path: path).call(method: "lento", params: [:], timeout: 0.3)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .timeout)
        }
    }

    /// Foco de revisión 3: app no corriendo.
    func testNoServerIsAppUnavailable() async throws {
        do {
            _ = try await ControlClient(path: path).call(method: "list_vms", params: [:], timeout: 1)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .appUnavailable)
        }
    }

    func testInvalidJSONGetsErrorAndConnectionSurvives() throws {
        try startServer { request in .success(id: request.id, result: "ok") }
        let channel = LineChannel(fd: try UnixSocket.connect(path: path))
        defer { channel.close() }
        channel.setReadTimeout(5)
        try channel.writeLine(Data("esto no es json".utf8))
        let bad = try JSONDecoder().decode(ControlResponse.self, from: XCTUnwrap(channel.readLine()))
        XCTAssertEqual(bad.error?.data, .invalidArgument)
        try channel.writeLine(JSONEncoder().encode(ControlRequest(id: 2, method: "x", params: [:])))
        let good = try JSONDecoder().decode(ControlResponse.self, from: XCTUnwrap(channel.readLine()))
        XCTAssertEqual(good.result, "ok")
    }

    func testConcurrentCalls() async throws {
        try startServer { request in
            try? await Task.sleep(for: .milliseconds(50))
            return .success(id: request.id, result: .string(request.method))
        }
        let client = ControlClient(path: path)
        let results = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for i in 0..<10 { group.addTask { try await client.call(method: "m\(i)", params: [:], timeout: 5) } }
            return try await group.reduce(into: [JSONValue]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(results.compactMap(\.stringValue)), Set((0..<10).map { "m\($0)" }))
    }

    func testStopRemovesSocket() async throws {
        try startServer { request in .success(id: request.id, result: nil) }
        server?.stop()
        server = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
