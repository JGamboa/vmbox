import ControlProtocol
import Foundation
@testable import MCPBridge

actor FakeControl: ControlCalling {
    var results: [Result<JSONValue, ControlError>]
    private(set) var calls: [(method: String, params: [String: JSONValue], timeout: Double)] = []

    init(_ results: [Result<JSONValue, ControlError>]) { self.results = results }

    func call(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        calls.append((method, params, timeout))
        return try results.removeFirst().get()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

struct FakeLauncher: AppLaunching {
    var succeeds = true
    let launches = Counter()

    func ensureRunning() async throws {
        launches.increment()
        if !succeeds { throw ControlError(code: .appUnavailable, message: "no arrancó") }
    }
}
