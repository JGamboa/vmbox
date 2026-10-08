import Darwin
import XCTest
@testable import ControlProtocol

/// Invitado simulado: un socketpair cuyo otro extremo responde una línea (o se cierra si `respond` devuelve nil).
struct FakeGuest: GuestConnecting {
    let respond: @Sendable (ControlRequest) -> String?

    func connect() async throws -> Int32 {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let guestFD = fds[1]
        let respond = self.respond
        Thread {
            let channel = LineChannel(fd: guestFD)
            defer { channel.close() }
            guard let line = try? channel.readLine(),
                  let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else { return }
            if let reply = respond(request) { try? channel.writeLine(Data(reply.utf8)) }
        }.start()
        return fds[0]
    }
}

struct RefusingGuest: GuestConnecting {
    func connect() async throws -> Int32 { throw POSIXError(.ECONNREFUSED) }
}

final class GuestAgentClientTests: XCTestCase {
    func testRoundTripWithGoShapedResponse() async throws {
        let guest = FakeGuest { request in
            #"{"jsonrpc":"2.0","id":\#(request.id),"result":{"stdout":"hola\n","exit_code":0}}"#
        }
        let result = try await GuestAgentClient(connector: guest).call(method: "run_command", params: ["command": "echo hola"], timeout: 5)
        XCTAssertEqual(result, ["stdout": "hola\n", "exit_code": 0])
    }

    func testGuestErrorIsPropagated() async {
        let guest = FakeGuest { request in
            #"{"jsonrpc":"2.0","id":\#(request.id),"error":{"code":-32000,"message":"path debe ser absoluta","data":"invalid_argument"}}"#
        }
        do {
            _ = try await GuestAgentClient(connector: guest).call(method: "read_file", params: ["path": "x"], timeout: 5)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error, ControlError(code: .invalidArgument, message: "path debe ser absoluta"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRefusedConnectionIsGuestAgentUnavailable() async {
        do {
            _ = try await GuestAgentClient(connector: RefusingGuest()).call(method: "ping", params: [:], timeout: 1)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .guestAgentUnavailable)
            XCTAssertTrue(error.message.contains("7000"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testClosedWithoutAnswerIsGuestAgentUnavailable() async {
        do {
            _ = try await GuestAgentClient(connector: FakeGuest { _ in nil }).call(method: "ping", params: [:], timeout: 2)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .guestAgentUnavailable)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSlowGuestTimesOut() async {
        let guest = FakeGuest { request in
            Thread.sleep(forTimeInterval: 2)
            return #"{"jsonrpc":"2.0","id":\#(request.id),"result":{}}"#
        }
        do {
            _ = try await GuestAgentClient(connector: guest).call(method: "run_command", params: [:], timeout: 0.3)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .timeout)
        } catch {
            XCTFail("\(error)")
        }
    }
}
