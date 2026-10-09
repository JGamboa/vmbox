import Foundation

public enum RPC {
    /// Envía una petición por `fd`, espera una respuesta y cierra el descriptor.
    public static func exchange(fd: Int32, method: String, params: [String: JSONValue], timeout: Double) throws -> JSONValue {
        try exchange(channel: LineChannel(fd: fd), method: method, params: params, timeout: timeout)
    }

    /// Igual que `exchange(fd:)`, sobre un canal que otro hilo puede cortar con `shutdown()`.
    public static func exchange(channel: LineChannel, method: String, params: [String: JSONValue], timeout: Double) throws -> JSONValue {
        defer { channel.close() }
        channel.setReadTimeout(timeout)
        let request = ControlRequest(id: Int.random(in: 1...Int(Int32.max)), method: method, params: params)
        do {
            try channel.writeLine(JSONEncoder().encode(request))
        } catch {
            throw ControlError(code: .appUnavailable, message: "No se pudo enviar la petición: \(error)")
        }
        let line: Data?
        do {
            line = try channel.readLine()
        } catch LineChannelError.timeout {
            throw ControlError(code: .timeout, message: "Sin respuesta tras \(Int(timeout)) s (\(method))")
        }
        guard let line else { throw ControlError(code: .appUnavailable, message: "La conexión se cerró sin respuesta") }
        let response: ControlResponse
        do {
            response = try JSONDecoder().decode(ControlResponse.self, from: line)
        } catch {
            throw ControlError(code: .internalError, message: "Respuesta inválida: \(error)")
        }
        return try response.get()
    }

    /// Ejecuta trabajo bloqueante en un hilo propio para no ocupar el pool cooperativo.
    public static func runOnThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try work() }) }.start()
        }
    }

    /// Espera de forma bloqueante una operación async (solo desde hilos propios, nunca del pool).
    static func blockingAwait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

/// Caja mutable para pasar un resultado entre una Task y un hilo bloqueado en un semáforo.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
