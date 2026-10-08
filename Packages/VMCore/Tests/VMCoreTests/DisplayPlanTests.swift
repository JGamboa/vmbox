import XCTest
@testable import VMCore

final class DisplayPlanTests: XCTestCase {
    func testRetinaLinuxUsesPointsAndPPI96() {
        let plan = DisplayPlan.make(for: .linux, screenWidthPoints: 1512, screenHeightPoints: 945, backingScale: 2)
        XCTAssertEqual(plan.windowWidth, 1208)
        XCTAssertEqual(plan.windowHeight, 752)
        XCTAssertEqual(plan.widthPixels, 1208)
        XCTAssertEqual(plan.heightPixels, 752)
        XCTAssertEqual(plan.pixelsPerInch, 96)
    }

    func testRetinaMacOSDoublesPixelsAndPPI144() {
        let plan = DisplayPlan.make(for: .macOS, screenWidthPoints: 1512, screenHeightPoints: 945, backingScale: 2)
        XCTAssertEqual(plan.widthPixels, 2416)
        XCTAssertEqual(plan.heightPixels, 1504)
        XCTAssertEqual(plan.pixelsPerInch, 144)
        XCTAssertEqual(plan.windowWidth, 1208)
    }

    func testExternal1080pScaleOne() {
        let linux = DisplayPlan.make(for: .linux, screenWidthPoints: 1920, screenHeightPoints: 1055, backingScale: 1)
        XCTAssertEqual(linux.widthPixels, 1536)
        XCTAssertEqual(linux.heightPixels, 840)
        let mac = DisplayPlan.make(for: .macOS, screenWidthPoints: 1920, screenHeightPoints: 1055, backingScale: 1)
        XCTAssertEqual(mac.widthPixels, 1536)
        XCTAssertEqual(mac.heightPixels, 840)
        XCTAssertEqual(mac.pixelsPerInch, 96)
    }

    func testMinimumAppliedOnSmallScreen() {
        let plan = DisplayPlan.make(for: .linux, screenWidthPoints: 1000, screenHeightPoints: 600, backingScale: 1)
        XCTAssertEqual(plan.windowWidth, 1024)
        XCTAssertEqual(plan.windowHeight, 640)
        XCTAssertEqual(plan.widthPixels, 1024)
        XCTAssertEqual(plan.heightPixels, 640)
    }

    func testAllDimensionsAreMultiplesOfEight() {
        for (w, h) in [(1512.0, 945.0), (1440, 900), (2560, 1415), (1728, 1079), (1366, 738)] {
            for os in [GuestOS.linux, .macOS] {
                for scale in [1.0, 2.0] {
                    let p = DisplayPlan.make(for: os, screenWidthPoints: w, screenHeightPoints: h, backingScale: scale)
                    XCTAssertEqual(p.widthPixels % 8, 0)
                    XCTAssertEqual(p.heightPixels % 8, 0)
                    XCTAssertEqual(Int(p.windowWidth) % 8, 0)
                    XCTAssertEqual(Int(p.windowHeight) % 8, 0)
                }
            }
        }
    }

    func testFallback() {
        XCTAssertEqual(DisplayPlan.fallback.widthPixels, 1920)
        XCTAssertEqual(DisplayPlan.fallback.heightPixels, 1200)
        XCTAssertEqual(DisplayPlan.fallback.pixelsPerInch, 144)
        XCTAssertEqual(DisplayPlan.fallback.windowWidth, 1280)
        XCTAssertEqual(DisplayPlan.fallback.windowHeight, 800)
    }
}
