import Foundation

public enum GuestAgent {
    public static let port: UInt32 = 7000
}

/// Abre una conexión nueva con el guest-agent y devuelve su descriptor; `GuestAgentClient` lo cierra.
public protocol GuestConnecting: Sendable {
    func connect() async throws -> Int32
}

/// Cliente del guest-agent: una conexión por llamada, mismo JSON-RPC por líneas que el socket de control.
public struct GuestAgentClient: Sendable {
    let connector: any GuestConnecting

    public init(connector: any GuestConnecting) {
        self.connector = connector
    }

    public func call(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        let fd: Int32
        do {
            fd = try await connector.connect()
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(code: .guestAgentUnavailable,
                               message: "El guest-agent no responde en vsock:\(GuestAgent.port). Instálalo desde Configuración de la VM ▸ Guest agent. (\(error.localizedDescription))")
        }
        // Cancelar la Task corta la conexión: el guest-agent lo detecta y mata el comando en curso.
        let channel = LineChannel(fd: fd)
        do {
            return try await withTaskCancellationHandler {
                try await RPC.runOnThread { try RPC.exchange(channel: channel, method: method, params: params, timeout: timeout) }
            } onCancel: {
                channel.shutdown()
            }
        } catch let error as ControlError where error.code == .appUnavailable {
            try Task.checkCancellation()
            throw ControlError(code: .guestAgentUnavailable, message: "El guest-agent cerró la conexión sin responder")
        }
    }
}
