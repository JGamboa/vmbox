import Darwin
import Foundation

public enum LineChannelError: Error, Equatable {
    case timeout
    case lineTooLong
    case posix(Int32)
}

/// Mensajes delimitados por "\n" sobre un descriptor de socket bloqueante.
public final class LineChannel: @unchecked Sendable {
    public static let maxLineBytes = 64 << 20

    public let fd: Int32
    private var buffer = Data()
    private var scanned = 0
    private let lock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public func setReadTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Lee hasta "\n" (sin incluirlo). Devuelve `nil` en EOF si no quedan datos.
    public func readLine() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            if let newline = findNewline() {
                let line = buffer.prefix(newline)
                buffer = Data(buffer.dropFirst(newline + 1))
                scanned = 0
                return Data(line)
            }
            scanned = buffer.count
            guard buffer.count <= Self.maxLineBytes else { throw LineChannelError.lineTooLong }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer = Data(); scanned = 0 }
                return buffer
            }
            switch errno {
            case EINTR: continue
            case EAGAIN: throw LineChannelError.timeout
            default: throw LineChannelError.posix(errno)
            }
        }
    }

    /// Busca "\n" solo en los bytes aún no revisados (las capturas en base64 ocupan varios MB).
    private func findNewline() -> Int? {
        buffer.withUnsafeBytes { raw -> Int? in
            guard raw.count > scanned, let base = raw.baseAddress,
                  let hit = memchr(base + scanned, 0x0A, raw.count - scanned) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    public func writeLine(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LineChannelError.posix(errno)
                }
                offset += n
            }
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
