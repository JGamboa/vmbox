import XCTest
@testable import VMCore

final class UbuntuReleaseTests: XCTestCase {
    func testURLsPointToLatestLTSDesktopArm64() {
        XCTAssertEqual(UbuntuRelease.isoFileName, "ubuntu-26.04.1-desktop-arm64.iso")
        XCTAssertEqual(UbuntuRelease.isoURL.absoluteString,
                       "https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso")
        XCTAssertEqual(UbuntuRelease.sha256SumsURL.absoluteString,
                       "https://cdimage.ubuntu.com/releases/26.04/release/SHA256SUMS")
    }

    func testParsesSHA256SUMS() {
        let sums = """
        c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57 *ubuntu-26.04-desktop-arm64.iso
        c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517 *ubuntu-26.04.1-desktop-arm64.iso
        """
        XCTAssertEqual(UbuntuRelease.parseSHA256(sums: sums, fileName: "ubuntu-26.04.1-desktop-arm64.iso"),
                       "c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517")
        XCTAssertNil(UbuntuRelease.parseSHA256(sums: sums, fileName: "otro.iso"))
    }
}
