import AgentControl
import ControlProtocol
import CoreGraphics
import Foundation
import VMCore

@MainActor
final class FakeVM: VMControlling {
    let id = UUID()
    var name: String
    var os: GuestOS = .linux
    var state: VMState
    var agentControlEnabled: Bool
    var metrics = ViewMetrics(width: 1280, height: 800, backingScale: 2, isFlipped: false)
    var performed: [InputAction] = []
    var startCount = 0
    var stopForces: [Bool] = []
    var snapshots: [SnapshotInfo] = []
    var restored: [String] = []
    var snapshotError: (any Error)?
    var guestCalls: [(method: String, params: [String: JSONValue], timeout: Double)] = []
    var guestReply: JSONValue = ["ok": true]

    func guestCall(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        guestCalls.append((method, params, timeout))
        return guestReply
    }

    init(name: String, state: VMState = .running, agentControlEnabled: Bool = true) {
        self.name = name
        self.state = state
        self.agentControlEnabled = agentControlEnabled
    }

    func start() async throws { startCount += 1; state = .running }
    func stop(force: Bool) async throws { stopForces.append(force); state = .stopped }
    func viewMetrics() async throws -> ViewMetrics { metrics }

    func createSnapshot(name: String) async throws -> SnapshotInfo {
        if let snapshotError { throw snapshotError }
        let info = SnapshotInfo(name: name, createdAt: Date(timeIntervalSince1970: 0), includesMemory: state == .running)
        snapshots.append(info)
        return info
    }

    func listSnapshots() throws -> [SnapshotInfo] { snapshots }

    func restoreSnapshot(name: String) async throws {
        if let snapshotError { throw snapshotError }
        guard snapshots.contains(where: { $0.name == name }) else { throw SnapshotError.notFound(name) }
        restored.append(name)
        state = .stopped
    }
    func perform(_ action: InputAction) async throws { performed.append(action) }

    func capture() async throws -> CapturedFrame {
        let width = max(1, Int(metrics.width * metrics.backingScale))
        let height = max(1, Int(metrics.height * metrics.backingScale))
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedFrame(image: ctx.makeImage()!, metrics: metrics)
    }
}

@MainActor
final class FakeDirectory: VMDirectory {
    var vms: [FakeVM]
    init(_ vms: [FakeVM]) { self.vms = vms }
    func allVMs() -> [any VMControlling] { vms }
}
