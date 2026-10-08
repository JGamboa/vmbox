import CryptoKit
import Foundation

public struct DownloadRequest: Sendable {
    public var url: URL
    public var destination: URL
    /// SHA256 en hexadecimal si la fuente lo publica (Ubuntu sí, Apple no).
    public var expectedSHA256: String?

    public init(url: URL, destination: URL, expectedSHA256: String?) {
        self.url = url
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
    }
}

public enum DownloadError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "El servidor respondió HTTP \(code)"
        case let .checksumMismatch(expected, actual): "SHA256 no coincide (esperado \(expected), obtenido \(actual))"
        }
    }
}

/// Descarga a `<destino>.part` con reanudación por `Range`, 3 intentos, validación de tamaño y SHA256.
/// Un fallo deja el `.part` para reanudar; cancelar lo borra.
public final class Downloader: Sendable {
    let session: URLSession
    let maxAttempts: Int
    let retryDelay: Duration

    public init(session: URLSession = .shared, maxAttempts: Int = 3, retryDelay: Duration = .seconds(2)) {
        self.session = session
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
    }

    public static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension("part")
    }

    public func download(_ request: DownloadRequest, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected = request.expectedSHA256?.lowercased()

        if fm.fileExists(atPath: request.destination.path) {
            if try expected == nil || Self.sha256(of: request.destination) == expected {
                progress(1)
                return request.destination
            }
            try fm.removeItem(at: request.destination)
        }

        let part = Self.partialURL(for: request.destination)
        do {
            var attempt = 1
            while true {
                do {
                    try await fetch(request.url, into: part, progress: progress)
                    break
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                    attempt += 1
                    try await Task.sleep(for: retryDelay)
                }
            }
        } catch is CancellationError {
            try? fm.removeItem(at: part)
            throw CancellationError()
        }

        if let expected {
            let actual = try Self.sha256(of: part)
            guard actual == expected else {
                try? fm.removeItem(at: part)
                throw DownloadError.checksumMismatch(expected: expected, actual: actual)
            }
        }
        try fm.moveItem(at: part, to: request.destination)
        progress(1)
        return request.destination
    }

    private func fetch(_ url: URL, into part: URL, progress: @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let existing = ((try fm.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0

        var urlRequest = URLRequest(url: url)
        if existing > 0 { urlRequest.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        var written: Int64
        switch status {
        case 206:
            written = existing
            try handle.seek(toOffset: UInt64(existing))
        case 200:
            written = 0
            try handle.truncate(atOffset: 0)
        case 416:
            // Solo es "completo" si Content-Range (`bytes */N`) coincide con el tamaño del parcial.
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
            if let header, header.hasPrefix("bytes */"), let total = Int64(header.dropFirst("bytes */".count)), total == existing {
                return
            }
            try handle.truncate(atOffset: 0)
            throw URLError(.networkConnectionLost)
        default:
            throw DownloadError.httpStatus(status)
        }

        let total = response.expectedContentLength > 0 ? written + response.expectedContentLength : -1
        let chunkSize = 1 << 20
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(written) / Double(total)) }
            }
        }
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        // Validación de tamaño: si el servidor anunció el total y llegó menos, es un corte; se reintenta reanudando.
        if total > 0, written < total { throw URLError(.networkConnectionLost) }
    }

    static func isRetryable(_ error: any Error) -> Bool {
        if let error = error as? DownloadError, case .httpStatus(let code) = error { return code >= 500 }
        return error is URLError
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
