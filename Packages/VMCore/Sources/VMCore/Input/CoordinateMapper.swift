import CoreGraphics
import Foundation

/// Espacio de la captura entregada al agente y tamaño de la vista a la que se mapea.
public struct CaptureGeometry: Codable, Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var viewWidth: Double
    public var viewHeight: Double

    public init(imageWidth: Int, imageHeight: Int, viewWidth: Double, viewHeight: Double) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
    }

    /// Píxeles de captura por punto de vista.
    public var scale: Double { Double(imageWidth) / viewWidth }
}

public enum CoordinateError: Error, Equatable, CustomStringConvertible {
    case outOfBounds(x: Double, y: Double, width: Int, height: Int)

    public var description: String {
        switch self {
        case let .outOfBounds(x, y, width, height):
            "Coordenadas (\(x), \(y)) fuera de la última captura de \(width)×\(height) px"
        }
    }
}

public enum CoordinateMapper {
    public static let maxImageWidth = 1280

    public static func geometry(sourcePixelWidth: Int, sourcePixelHeight: Int, viewWidth: Double, viewHeight: Double) -> CaptureGeometry {
        let width = min(maxImageWidth, max(1, sourcePixelWidth))
        let height = max(1, Int((Double(sourcePixelHeight) * Double(width) / Double(max(1, sourcePixelWidth))).rounded()))
        return CaptureGeometry(imageWidth: width, imageHeight: height, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// (x, y) con origen arriba-izquierda en píxeles de la captura → punto de la vista.
    public static func viewPoint(x: Double, y: Double, in g: CaptureGeometry, viewIsFlipped: Bool) throws -> CGPoint {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(g.imageWidth), y < Double(g.imageHeight) else {
            throw CoordinateError.outOfBounds(x: x, y: y, width: g.imageWidth, height: g.imageHeight)
        }
        let viewX = x * g.viewWidth / Double(g.imageWidth)
        let fromTop = y * g.viewHeight / Double(g.imageHeight)
        return CGPoint(x: viewX, y: viewIsFlipped ? fromTop : g.viewHeight - fromTop)
    }
}
