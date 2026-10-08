import Foundation

public enum ControlErrorCode: String, Codable, Sendable {
    case agentControlDisabled = "agent_control_disabled"
    case vmNotFound = "vm_not_found"
    case vmNotRunning = "vm_not_running"
    case timeout
    case appUnavailable = "app_unavailable"
    case invalidArgument = "invalid_argument"
    case internalError = "internal_error"
}

public struct ControlError: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: ControlErrorCode
    public var message: String

    public init(code: ControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "\(code.rawValue): \(message)" }
}

/// Petición JSON-RPC 2.0 (una por línea).
public struct ControlRequest: Codable, Equatable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int
    public var method: String
    public var params: [String: JSONValue]

    public init(id: Int, method: String, params: [String: JSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCErrorObject: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: ControlErrorCode
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int
    public var result: JSONValue?
    public var error: RPCErrorObject?

    public static func success(id: Int, result: JSONValue) -> ControlResponse {
        ControlResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: Int, error: ControlError) -> ControlResponse {
        ControlResponse(id: id, result: nil, error: RPCErrorObject(code: -32000, message: error.message, data: error.code))
    }

    public func get() throws -> JSONValue {
        if let error { throw ControlError(code: error.data, message: error.message) }
        return result ?? .null
    }
}
