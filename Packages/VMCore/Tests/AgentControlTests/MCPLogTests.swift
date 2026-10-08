import AgentControl
import XCTest

@MainActor
final class MCPLogTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "mcplog-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func entry(_ n: Int) -> MCPLogEntry { MCPLogEntry(method: "click", vm: "u\(n)", errorCode: nil, durationMs: n) }

    func testRecordsInMemoryAndFile() throws {
        let file = dir.appending(path: "mcp.log")
        let log = MCPLog(fileURL: file)
        (0..<3).forEach { log.record(entry($0)) }
        XCTAssertEqual(log.recent.map(\.vm), ["u0", "u1", "u2"])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\"method\":\"click\""))
    }

    func testKeepsOnlyRecentInMemory() {
        let log = MCPLog(fileURL: nil, keepInMemory: 2)
        (0..<5).forEach { log.record(entry($0)) }
        XCTAssertEqual(log.recent.map(\.vm), ["u3", "u4"])
    }

    func testRotatesWhenTooBig() throws {
        let file = dir.appending(path: "mcp.log")
        let log = MCPLog(fileURL: file, maxBytes: 400)
        (0..<20).forEach { log.record(entry($0)) }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 400)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".1"))
    }
}
