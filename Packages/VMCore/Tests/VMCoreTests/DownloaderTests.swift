import CryptoKit
import XCTest
@testable import VMCore

final class DownloaderTests: XCTestCase {
    var tmp: TemporaryDirectory!
    let body = Data("contenido de prueba de VMBox".utf8)
    let url = URL(string: "https://example.test/archivo.iso")!
    var sha: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    var destination: URL { tmp.url.appending(path: "archivo.iso") }

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        StubURLProtocol.reset()
    }

    func makeDownloader(maxAttempts: Int = 3, retryDelay: Duration = .zero) -> Downloader {
        Downloader(session: StubURLProtocol.session(), maxAttempts: maxAttempts, retryDelay: retryDelay)
    }

    func testDownloadsAndVerifiesChecksum() async throws {
        StubURLProtocol.handler = { _ in .init(body: self.body) }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(try Data(contentsOf: result), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path))
    }

    /// Foco de revisión 4: SHA256 incorrecto no deja archivo final ni parcial.
    func testChecksumMismatchLeavesNothing() async throws {
        StubURLProtocol.handler = { _ in .init(body: self.body) }
        do {
            _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: String(repeating: "0", count: 64)))
            XCTFail("debió lanzar")
        } catch DownloadError.checksumMismatch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path))
    }

    /// Foco de revisión 4: una descarga cortada se reanuda con Range.
    func testResumesFromPartialFileWithRange() async throws {
        try body.prefix(5).write(to: Downloader.partialURL(for: destination))
        StubURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=5-" {
                return .init(status: 206, body: self.body.dropFirst(5))
            }
            return .init(body: self.body)
        }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(try Data(contentsOf: result), body)
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=5-")
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        try Data("basura".utf8).write(to: Downloader.partialURL(for: destination))
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.body) }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(try Data(contentsOf: result), body)
    }

    /// Spec §6: validación de tamaño (el IPSW no publica SHA256). Llega menos de lo anunciado → reanuda.
    func testShortBodyIsResumed() async throws {
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            if calls == 1 { return .init(body: self.body.prefix(5), declaredLength: self.body.count) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=5-")
            return .init(status: 206, body: self.body.dropFirst(5))
        }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: nil))
        XCTAssertEqual(try Data(contentsOf: result), body)
        XCTAssertEqual(calls, 2)
    }

    func testRetriesTransientErrors() async throws {
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            return calls < 3 ? .init(error: URLError(.networkConnectionLost)) : .init(body: self.body)
        }
        _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(calls, 3)
    }

    func testGivesUpAfterThreeAttemptsAndKeepsPartial() async throws {
        StubURLProtocol.handler = { _ in .init(error: URLError(.networkConnectionLost)) }
        do {
            _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: nil))
            XCTFail("debió lanzar")
        } catch {}
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path), "el parcial queda para reanudar")
    }

    func testClientErrorIsNotRetried() async throws {
        StubURLProtocol.handler = { _ in .init(status: 404) }
        do {
            _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: nil))
            XCTFail("debió lanzar")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .httpStatus(404))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    /// Foco de revisión 4: cancelar borra el parcial.
    func testCancellationRemovesPartial() async throws {
        StubURLProtocol.handler = { _ in .init(error: URLError(.networkConnectionLost)) }
        let downloader = makeDownloader(retryDelay: .seconds(10))
        let request = DownloadRequest(url: url, destination: destination, expectedSHA256: nil)
        let task = Task { try await downloader.download(request) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("debió lanzar")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path))
    }

    func testExistingVerifiedFileSkipsNetwork() async throws {
        try body.write(to: destination)
        _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }
}
