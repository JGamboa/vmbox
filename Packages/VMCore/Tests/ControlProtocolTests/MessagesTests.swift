import XCTest
@testable import ControlProtocol

final class MessagesTests: XCTestCase {
    func testDecodesMixedJSON() throws {
        let json = #"{"a":[1,true,null,"x",{"b":2.5}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value, ["a": [1, true, nil, "x", ["b": 2.5]]])
    }

    func testRoundTrip() throws {
        let value: JSONValue = ["vm": "Ubuntu", "x": 10, "ok": false, "list": [1, 2]]
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testDecodeIntoStruct() throws {
        struct Params: Decodable, Equatable { var vm: String; var x: Double; var count: Int? }
        let value: JSONValue = ["vm": "u", "x": 10.5, "count": 2]
        XCTAssertEqual(try value.decode(as: Params.self), Params(vm: "u", x: 10.5, count: 2))
        XCTAssertThrowsError(try JSONValue.object(["vm": "u"]).decode(as: Params.self))
    }

    func testEncodingInitializer() throws {
        struct S: Encodable { var name = "a"; var n = 3 }
        XCTAssertEqual(try JSONValue(encoding: S()), ["name": "a", "n": 3])
    }

    func testRequestShape() throws {
        let data = try JSONEncoder().encode(ControlRequest(id: 7, method: "list_vms", params: [:]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual(object["method"] as? String, "list_vms")
    }

    func testFailureCarriesCodeAsData() throws {
        let response = ControlResponse.failure(id: 3, error: ControlError(code: .vmNotFound, message: "no existe"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(error["data"] as? String, "vm_not_found")
        XCTAssertThrowsError(try response.get()) { thrown in
            XCTAssertEqual(thrown as? ControlError, ControlError(code: .vmNotFound, message: "no existe"))
        }
    }

    func testSuccessGet() throws {
        XCTAssertEqual(try ControlResponse.success(id: 1, result: ["ok": true]).get(), ["ok": true])
    }

    func testSocketPathIsInApplicationSupport() {
        XCTAssertTrue(ControlPaths.socketPath.hasSuffix("Library/Application Support/VMBox/control.sock"))
    }
}
