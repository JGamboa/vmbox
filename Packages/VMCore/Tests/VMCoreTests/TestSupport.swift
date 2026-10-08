import Foundation

/// Directorio temporal único que se borra al liberar el objeto.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "vmcore-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: Data = Data()) throws -> URL {
        let file = url.appending(path: name)
        try contents.write(to: file)
        return file
    }
}
