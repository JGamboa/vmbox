import ControlProtocol
import Foundation
import XCTest
@testable import MCPBridge

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String]] = []
    private var probes = 0
    func add(_ args: [String]) { lock.withLock { items.append(args) } }
    var calls: [[String]] { lock.withLock { items } }
    func nextProbe() -> Int { lock.withLock { probes += 1; return probes } }
}

final class AppLauncherTests: XCTestCase {
    func testBundleFromEmbeddedExecutable() {
        XCTAssertEqual(AppLauncher.appBundle(forExecutable: URL(filePath: "/Applications/VMBox.app/Contents/MacOS/vmbox-mcp"))?.path,
                       "/Applications/VMBox.app")
        XCTAssertNil(AppLauncher.appBundle(forExecutable: URL(filePath: "/usr/local/bin/vmbox-mcp")))
    }

    func testOpensBundleAndWaitsForSocket() async throws {
        let recorder = Recorder()
        let launcher = AppLauncher(socketPath: "/tmp/x.sock", appBundle: URL(filePath: "/Applications/VMBox.app"),
                                   timeout: .seconds(5), open: { recorder.add($0) },
                                   canConnect: { _ in recorder.nextProbe() >= 3 })
        try await launcher.ensureRunning()
        XCTAssertEqual(recorder.calls, [["/Applications/VMBox.app"]])
    }

    func testFallsBackToOpenDashA() async throws {
        let recorder = Recorder()
        let launcher = AppLauncher(socketPath: "/tmp/x.sock", appBundle: nil, timeout: .seconds(1),
                                   open: { recorder.add($0) }, canConnect: { _ in true })
        try await launcher.ensureRunning()
        XCTAssertEqual(recorder.calls, [["-a", "VMBox"]])
    }

    func testTimesOutWithAppUnavailable() async {
        let launcher = AppLauncher(socketPath: "/tmp/x.sock", appBundle: nil, timeout: .milliseconds(300),
                                   open: { _ in }, canConnect: { _ in false })
        do {
            try await launcher.ensureRunning()
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .appUnavailable)
        } catch {
            XCTFail("\(error)")
        }
    }
}
