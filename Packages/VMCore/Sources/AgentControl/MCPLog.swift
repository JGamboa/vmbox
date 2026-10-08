import Foundation
import Observation

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
@Observable
public final class MCPLog {
    public private(set) var recent: [MCPLogEntry] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let maxBytes: Int
    @ObservationIgnored private let keepInMemory: Int

    public init(fileURL: URL?, maxBytes: Int = 1_000_000, keepInMemory: Int = 200) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.keepInMemory = keepInMemory
    }

    public func record(_ entry: MCPLogEntry) {
        recent.append(entry)
        if recent.count > keepInMemory { recent.removeFirst(recent.count - keepInMemory) }
        if let fileURL { append(entry, to: fileURL) }
    }

    private func append(_ entry: MCPLogEntry, to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = ((try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if size > 0, size + line.count > maxBytes {
            let rotated = URL(filePath: fileURL.path + ".1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }
}
