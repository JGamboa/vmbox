import Darwin
import Foundation

public enum UnixSocketError: Error, Equatable, LocalizedError {
    case pathTooLong(String)
    case alreadyInUse(String)
    case posix(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "Ruta de socket demasiado larga: \(path)"
        case .alreadyInUse(let path): "Otra instancia de VMBox ya escucha en \(path)"
        case let .posix(call, code): "\(call) falló: \(String(cString: strerror(code)))"
        }
    }
}

public enum UnixSocket {
    static func address(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw UnixSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }

    /// Escucha en `path` con permisos 0600. Borra un socket viejo; falla si otro proceso ya escucha.
    public static func listen(path: String) throws -> Int32 {
        var addr = try address(path: path)
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? connect(path: path) {
                Darwin.close(probe)
                throw UnixSocketError.alreadyInUse(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.posix("socket", errno) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("bind", code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("chmod", code)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("listen", code)
        }
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        var addr = try address(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.posix("socket", errno) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("connect", code)
        }
        return fd
    }
}
