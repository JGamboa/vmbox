import CoreGraphics
import ImageIO
import XCTest
@testable import VMCore

final class CoordinateMapperTests: XCTestCase {
    func testRetinaCaptureIsScaledTo1280() {
        let g = CoordinateMapper.geometry(sourcePixelWidth: 2560, sourcePixelHeight: 1600, viewWidth: 1280, viewHeight: 800)
        XCTAssertEqual(g, CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 1280, viewHeight: 800))
        XCTAssertEqual(g.scale, 1)
    }

    func testSmallCaptureIsNotUpscaled() {
        let g = CoordinateMapper.geometry(sourcePixelWidth: 1000, sourcePixelHeight: 500, viewWidth: 500, viewHeight: 250)
        XCTAssertEqual(g.imageWidth, 1000)
        XCTAssertEqual(g.imageHeight, 500)
        XCTAssertEqual(g.scale, 2)
    }

    func testMapsTopLeftOriginToAppKitPoint() throws {
        let g = CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 1280, viewHeight: 800)
        XCTAssertEqual(try CoordinateMapper.viewPoint(x: 100, y: 50, in: g, viewIsFlipped: false), CGPoint(x: 100, y: 750))
        XCTAssertEqual(try CoordinateMapper.viewPoint(x: 100, y: 50, in: g, viewIsFlipped: true), CGPoint(x: 100, y: 50))
    }

    /// Foco de revisión 2: tras redimensionar, el punto cae en el mismo lugar relativo.
    func testMapsIntoSmallerView() throws {
        let g = CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 640, viewHeight: 400)
        XCTAssertEqual(try CoordinateMapper.viewPoint(x: 100, y: 50, in: g, viewIsFlipped: false), CGPoint(x: 50, y: 375))
    }

    /// Foco de revisión 2: fuera de la captura → error.
    func testOutOfBounds() {
        let g = CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 1280, viewHeight: 800)
        for (x, y) in [(1280.0, 10.0), (-1, 10), (10, 800), (.nan, 1), (.infinity, 1)] {
            XCTAssertThrowsError(try CoordinateMapper.viewPoint(x: x, y: y, in: g, viewIsFlipped: false), "\(x),\(y)") { error in
                XCTAssertTrue("\(error)".contains("1280×800"))
            }
        }
    }

    func testEncodesScaledPNG() throws {
        let ctx = CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
        let png = try ScreenshotEncoder.png(from: ctx.makeImage()!, width: 1280, height: 800)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1280)
        XCTAssertEqual(image.height, 800)
    }
}
