import Foundation

/// Cliente del socket de control: una conexión por llamada.
public struct ControlClient: Sendable {
    public let path: String

    public init(path: String = ControlPaths.socketPath) {
        self.path = path
    }

    public func call(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        let path = self.path
        return try await RPC.runOnThread {
            let fd: Int32
            do {
                fd = try UnixSocket.connect(path: path)
            } catch {
                throw ControlError(code: .appUnavailable, message: "VMBox no está escuchando en \(path)")
            }
            return try RPC.exchange(fd: fd, method: method, params: params, timeout: timeout)
        }
    }
}
