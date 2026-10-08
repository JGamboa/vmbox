import CoreGraphics
import Foundation
import VMCore

public struct ViewMetrics: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var backingScale: Double
    public var isFlipped: Bool

    public init(width: Double, height: Double, backingScale: Double, isFlipped: Bool) {
        self.width = width
        self.height = height
        self.backingScale = backingScale
        self.isFlipped = isFlipped
    }
}

public struct CapturedFrame: @unchecked Sendable {
    public var image: CGImage
    public var metrics: ViewMetrics

    public init(image: CGImage, metrics: ViewMetrics) {
        self.image = image
        self.metrics = metrics
    }
}

public enum MouseButton: String, Codable, Sendable { case left, right }

/// Acción de entrada ya traducida a puntos de la vista (AppKit).
public enum InputAction: Equatable, Sendable {
    case click(at: CGPoint, button: MouseButton, count: Int)
    case drag(from: CGPoint, to: CGPoint)
    case scroll(at: CGPoint, dx: Double, dy: Double)
    case keys([KeyStroke])
}

/// Lo que el servicio de control necesita de una VM. La app lo implementa sobre VMInstance + su vista.
@MainActor
public protocol VMControlling: AnyObject {
    var id: UUID { get }
    var name: String { get }
    var os: GuestOS { get }
    var state: VMState { get }
    var agentControlEnabled: Bool { get }
    /// Inicia la VM y abre su ventana.
    func start() async throws
    func stop(force: Bool) async throws
    /// Tamaño de la vista; abre la ventana si hace falta.
    func viewMetrics() async throws -> ViewMetrics
    func capture() async throws -> CapturedFrame
    func perform(_ action: InputAction) async throws
    func createSnapshot(name: String) async throws -> SnapshotInfo
    func listSnapshots() throws -> [SnapshotInfo]
    /// Detiene la VM y restaura el snapshot.
    func restoreSnapshot(name: String) async throws
}

@MainActor
public protocol VMDirectory: AnyObject {
    func allVMs() -> [any VMControlling]
}
