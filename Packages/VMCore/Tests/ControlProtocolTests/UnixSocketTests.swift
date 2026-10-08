import Darwin
import XCTest
@testable import ControlProtocol

/// Ruta corta en /tmp: sun_path admite 103 bytes.
func makeSocketPath() -> String { "/tmp/vmbox-test-\(UUID().uuidString.prefix(8)).sock" }

final class UnixSocketTests: XCTestCase {
    func testRejectsTooLongPath() {
        let path = "/tmp/" + String(repeating: "a", count: 120)
        XCTAssertThrowsError(try UnixSocket.listen(path: path)) { error in
            XCTAssertEqual(error as? UnixSocketError, .pathTooLong(path))
        }
    }

    func testListenCreatesSocketWith0600() throws {
        let path = makeSocketPath()
        let fd = try UnixSocket.listen(path: path)
        defer { close(fd); unlink(path) }
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    /// Foco de revisión 3: un socket viejo (sin nadie escuchando) se reemplaza.
    func testStaleSocketIsReplaced() throws {
        let path = makeSocketPath()
        let old = try UnixSocket.listen(path: path)
        close(old) // el archivo queda, pero nadie escucha
        let fd = try UnixSocket.listen(path: path)
        defer { close(fd); unlink(path) }
        let client = try UnixSocket.connect(path: path)
        close(client)
    }

    /// Foco de revisión 3: no robar el socket de otra instancia viva.
    func testLiveSocketIsNotStolen() throws {
        let path = makeSocketPath()
        let fd = try UnixSocket.listen(path: path)
        defer { close(fd); unlink(path) }
        XCTAssertThrowsError(try UnixSocket.listen(path: path)) { error in
            XCTAssertEqual(error as? UnixSocketError, .alreadyInUse(path))
        }
    }

    func testConnectWithoutServerFails() {
        XCTAssertThrowsError(try UnixSocket.connect(path: makeSocketPath()))
    }
}
