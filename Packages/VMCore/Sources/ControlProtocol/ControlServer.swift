import Darwin
import Foundation

/// Servidor del socket de control. Acepta con un DispatchSource y atiende cada conexión
/// en un hilo propio (lectura bloqueante, una respuesta por petición).
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "vmbox.control.accept")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let fd = try UnixSocket.listen(path: path)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            let handler = self.handler
            Thread { ControlServer.serve(fd: client, handler: handler) }.start()
        }
    }

    static func serve(fd: Int32, handler: @escaping Handler) {
        let channel = LineChannel(fd: fd)
        defer { channel.close() }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        while let line = try? channel.readLine() {
            let response: ControlResponse
            if let request = try? decoder.decode(ControlRequest.self, from: line) {
                response = RPC.blockingAwait { await handler(request) }
            } else {
                response = .failure(id: 0, error: ControlError(code: .invalidArgument, message: "Mensaje JSON-RPC inválido"))
            }
            guard let data = try? encoder.encode(response), (try? channel.writeLine(data)) != nil else { return }
        }
    }
}
