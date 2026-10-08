import XCTest
@testable import VMCore

final class VMConfigTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let mac = VMConfig.defaults(for: .macOS, name: "m")
        XCTAssertEqual(mac.cpuCount, 4)
        XCTAssertEqual(mac.memoryBytes, 8 * .gib)
        XCTAssertEqual(mac.diskBytes, 80 * .gib)
        let linux = VMConfig.defaults(for: .linux, name: "u")
        XCTAssertEqual(linux.cpuCount, 4)
        XCTAssertEqual(linux.memoryBytes, 4 * .gib)
        XCTAssertEqual(linux.diskBytes, 40 * .gib)
        XCTAssertFalse(linux.agentControlEnabled)
        XCTAssertTrue(linux.sharedFolders.isEmpty)
    }

    func testRoundTrip() throws {
        var config = VMConfig.defaults(for: .linux, name: "Ubuntu")
        config.sharedFolders = [SharedFolder(path: "/tmp/x", readOnly: true)]
        config.agentControlEnabled = true
        config.installMediaPath = "/tmp/u.iso"
        XCTAssertEqual(try VMConfig.decode(from: config.encoded()), config)
    }

    func testEncodesOSAsLowercaseString() throws {
        let json = String(decoding: try VMConfig.defaults(for: .macOS, name: "m").encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"os\" : \"macos\""), json)
    }

    /// Foco de revisión 5: config.json antiguo o editado a mano sin claves opcionales.
    func testMissingOptionalKeysUseDefaults() throws {
        let json = """
        {"id":"8C1F7E8E-2F7B-4C1B-9E1A-7D3F0B6B9A10","name":"vieja","os":"linux","cpuCount":2,
         "memoryBytes":2147483648,"diskBytes":10737418240,"macAddress":"02:00:00:00:00:01"}
        """
        let config = try VMConfig.decode(from: Data(json.utf8))
        XCTAssertFalse(config.agentControlEnabled)
        XCTAssertEqual(config.sharedFolders, [])
        XCTAssertNil(config.installMediaPath)
    }

    func testRandomMACIsLocallyAdministeredUnicast() throws {
        for _ in 0..<50 {
            let mac = MACAddress.randomLocallyAdministered()
            XCTAssertNotNil(mac.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression), mac)
            let first = try XCTUnwrap(UInt8(mac.prefix(2), radix: 16))
            XCTAssertEqual(first & 0b11, 0b10, "bit local=1, bit multicast=0")
        }
    }
}
