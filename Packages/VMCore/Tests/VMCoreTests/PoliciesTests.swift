import XCTest
@testable import VMCore

final class PoliciesTests: XCTestCase {
    func testThirdMacOSIsRejected() {
        XCTAssertEqual(StartPolicy.check(starting: .macOS, running: [.macOS]), .ok)
        XCTAssertEqual(StartPolicy.check(starting: .macOS, running: [.macOS, .macOS]), .macOSLimitReached)
        XCTAssertEqual(StartPolicy.check(starting: .linux, running: [.macOS, .macOS, .linux]), .ok)
    }

    func testEnsureThrowsWhenInsufficient() {
        XCTAssertNoThrow(try DiskSpace.ensure(10, available: 10))
        XCTAssertThrowsError(try DiskSpace.ensure(11, available: 10)) { error in
            XCTAssertEqual(error as? DiskSpaceError, .insufficient(required: 11, available: 10))
        }
    }

    func testAvailableReadsVolume() throws {
        XCTAssertGreaterThan(try DiskSpace.available(at: FileManager.default.temporaryDirectory), 0)
    }

    func testRequiredForCreate() {
        XCTAssertEqual(DiskSpace.requiredForCreate(.macOS), 50 * .gib)
        XCTAssertEqual(DiskSpace.requiredForCreate(.linux), 15 * .gib)
    }
}
