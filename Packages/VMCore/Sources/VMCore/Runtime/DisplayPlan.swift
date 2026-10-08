import Foundation

/// Resolución del invitado y tamaño de ventana (en puntos) que la muestra 1:1,
/// derivados del área visible de la pantalla del anfitrión.
public struct DisplayPlan: Equatable, Sendable {
    public var widthPixels: Int
    public var heightPixels: Int
    public var pixelsPerInch: Int
    /// Tamaño de la ventana (en puntos) que muestra la VM 1:1.
    public var windowWidth: Double
    public var windowHeight: Double

    public init(widthPixels: Int, heightPixels: Int, pixelsPerInch: Int, windowWidth: Double, windowHeight: Double) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.pixelsPerInch = pixelsPerInch
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }

    public static let fallback = DisplayPlan(widthPixels: 1920, heightPixels: 1200, pixelsPerInch: 144,
                                             windowWidth: 1280, windowHeight: 800)

    private static let minWidth = 1024
    private static let minHeight = 640

    /// Ventana = 80 % del área visible (puntos), hacia abajo a múltiplo de 8, mínimo 1024×640.
    public static func make(for os: GuestOS, screenWidthPoints: Double, screenHeightPoints: Double, backingScale: Double) -> DisplayPlan {
        let width = max(minWidth, floorToEight(screenWidthPoints * 0.8))
        let height = max(minHeight, floorToEight(screenHeightPoints * 0.8))
        switch os {
        case .linux:
            return DisplayPlan(widthPixels: width, heightPixels: height, pixelsPerInch: 96,
                               windowWidth: Double(width), windowHeight: Double(height))
        case .macOS:
            let scale = max(1, backingScale)
            return DisplayPlan(widthPixels: floorToEight(Double(width) * scale),
                               heightPixels: floorToEight(Double(height) * scale),
                               pixelsPerInch: scale >= 2 ? 144 : 96,
                               windowWidth: Double(width), windowHeight: Double(height))
        }
    }

    private static func floorToEight(_ value: Double) -> Int { Int(value / 8) * 8 }
}
