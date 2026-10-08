import Darwin
import XCTest
@testable import ControlProtocol

final class LineChannelTests: XCTestCase {
    func makePair() -> (LineChannel, LineChannel) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (LineChannel(fd: fds[0]), LineChannel(fd: fds[1]))
    }

    func testLinesArriveInOrder() throws {
        let (a, b) = makePair()
        defer { a.close(); b.close() }
        try a.writeLine(Data("uno".utf8))
        try a.writeLine(Data("dos".utf8))
        XCTAssertEqual(try b.readLine(), Data("uno".utf8))
        XCTAssertEqual(try b.readLine(), Data("dos".utf8))
    }

    func testLargeLine() throws {
        let (a, b) = makePair()
        defer { a.close(); b.close() }
        let big = Data(repeating: UInt8(ascii: "x"), count: 5 << 20)
        let writer = Thread { try? a.writeLine(big) }
        writer.start()
        XCTAssertEqual(try b.readLine()?.count, big.count)
    }

    func testEOFReturnsNil() throws {
        let (a, b) = makePair()
        a.close()
        XCTAssertNil(try b.readLine())
        b.close()
    }

    func testReadTimeout() throws {
        let (a, b) = makePair()
        defer { a.close(); b.close() }
        b.setReadTimeout(0.2)
        let start = Date()
        XCTAssertThrowsError(try b.readLine()) { error in
            XCTAssertEqual(error as? LineChannelError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Foco de revisión 3: escribir a un par cerrado lanza en vez de matar el proceso con SIGPIPE.
    func testWriteToClosedPeerThrows() throws {
        let (a, b) = makePair()
        b.close()
        XCTAssertThrowsError(try a.writeLine(Data("hola".utf8)))
        a.close()
    }
}
