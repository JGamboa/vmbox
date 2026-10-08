import ControlProtocol
import Darwin
import Virtualization
import VMCore

/// Conecta con el guest-agent por el VZVirtioSocketDevice de la VM.
@MainActor
final class VsockGuestConnector: GuestConnecting {
    private weak var instance: VMInstance?

    init(instance: VMInstance) {
        self.instance = instance
    }

    func connect() async throws -> Int32 {
        guard let device = instance?.machine?.socketDevices.first as? VZVirtioSocketDevice else {
            throw ControlError(code: .vmNotRunning, message: "La VM no está en ejecución")
        }
        let connection = try await device.connect(toPort: GuestAgent.port)
        // La conexión cierra su descriptor al liberarse: duplicarlo para que lo gestione LineChannel.
        let fd = dup(connection.fileDescriptor)
        connection.close()
        guard fd >= 0 else { throw ControlError(code: .internalError, message: "dup falló: \(errno)") }
        return fd
    }
}
