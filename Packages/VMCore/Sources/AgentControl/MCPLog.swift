import Foundation

public struct MCPLogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var method: String
    public var vm: String?
    public var errorCode: String?
    public var durationMs: Int

    public var ok: Bool { errorCode == nil }

    public init(method: String, vm: String?, errorCode: String?, durationMs: Int) {
        self.method = method
        self.vm = vm
        self.errorCode = errorCode
        self.durationMs = durationMs
    }
}

@MainActor
public final class MCPLog {
    public func record(_ entry: MCPLogEntry) {}
}
