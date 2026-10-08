import CryptoKit
import XCTest
@testable import VMCore

final class LinuxVMCreatorTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
        StubURLProtocol.reset()
    }

    func makeCreator() -> LinuxVMCreator {
        let session = StubURLProtocol.session()
        return LinuxVMCreator(library: library, downloader: Downloader(session: session, retryDelay: .zero),
                              cacheDir: tmp.url.appending(path: "Cache", directoryHint: .isDirectory),
                              session: session, requiredFreeBytes: 0)
    }

    func testLocalISOIsAttachedAsInstallMedia() async throws {
        let iso = try tmp.file("mio.iso", contents: Data(count: 1024))
        let bundle = try await makeCreator().create(config: .defaults(for: .linux, name: "u"), localISO: iso) { _ in }
        XCTAssertEqual(try bundle.readConfig().installMediaPath, iso.path)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testDownloadsLatestISOWithPublishedChecksum() async throws {
        let isoBytes = Data("iso falso".utf8)
        let sha = SHA256.hash(data: isoBytes).map { String(format: "%02x", $0) }.joined()
        StubURLProtocol.handler = { request in
            if request.url == UbuntuRelease.sha256SumsURL {
                return .init(body: Data("\(sha) *\(UbuntuRelease.isoFileName)\n".utf8))
            }
            return .init(body: isoBytes)
        }
        let bundle = try await makeCreator().create(config: .defaults(for: .linux, name: "u"), localISO: nil) { _ in }
        let path = try XCTUnwrap(try bundle.readConfig().installMediaPath)
        XCTAssertTrue(path.hasSuffix("Cache/\(UbuntuRelease.isoFileName)"))
        XCTAssertEqual(try Data(contentsOf: URL(filePath: path)), isoBytes)
    }

    func testMissingChecksumFailsWithoutCreatingBundle() async throws {
        StubURLProtocol.handler = { _ in .init(body: Data("nada\n".utf8)) }
        do {
            _ = try await makeCreator().create(config: .defaults(for: .linux, name: "u"), localISO: nil) { _ in }
            XCTFail("debió lanzar")
        } catch CreationError.checksumUnavailable {}
        XCTAssertEqual(try library.list().entries.count, 0)
    }
}
