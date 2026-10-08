import ControlProtocol
import CoreGraphics
import Foundation
import VMCore

/// Enruta cada método del socket de control: busca la VM, aplica permisos y estado,
/// valida argumentos, convierte coordenadas y delega en `VMControlling`.
@MainActor
public final class ControlService {
    private let directory: any VMDirectory
    private let log: MCPLog?
    private var lastGeometry: [UUID: CaptureGeometry] = [:]
    public var onAgentActivity: (UUID) -> Void = { _ in }

    public init(directory: any VMDirectory, log: MCPLog? = nil) {
        self.directory = directory
        self.log = log
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        let started = ContinuousClock.now
        let response: ControlResponse
        do {
            response = .success(id: request.id, result: try await dispatch(request))
        } catch {
            response = .failure(id: request.id, error: Self.controlError(from: error))
        }
        let elapsed = ContinuousClock.now - started
        log?.record(MCPLogEntry(
            method: request.method, vm: request.params["vm"]?.stringValue,
            errorCode: response.error?.data.rawValue,
            durationMs: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        ))
        return response
    }

    // MARK: Parámetros

    struct StopParams: Decodable { var vm: String; var force: Bool? }
    struct ClickParams: Decodable { var vm: String; var x: Double; var y: Double; var button: MouseButton?; var count: Int? }
    struct DragParams: Decodable {
        var vm: String; var fromX: Double; var fromY: Double; var toX: Double; var toY: Double
        enum CodingKeys: String, CodingKey { case vm, fromX = "from_x", fromY = "from_y", toX = "to_x", toY = "to_y" }
    }
    struct ScrollParams: Decodable { var vm: String; var x: Double; var y: Double; var dx: Double; var dy: Double }
    struct TextParams: Decodable { var vm: String; var text: String }
    struct KeyParams: Decodable { var vm: String; var combo: String }

    // MARK: Despacho

    /// Métodos que actúan sobre una VM (todos salvo list_vms). Las Fases 3 y 4 añaden los suyos.
    static let vmMethods: Set<String> = ["start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key"]

    func dispatch(_ request: ControlRequest) async throws -> JSONValue {
        if request.method == "list_vms" {
            return ["vms": .array(directory.allVMs().map { vm in
                ["name": .string(vm.name), "os": .string(vm.os.rawValue), "state": .string(vm.state.rawValue),
                 "agentControlEnabled": .bool(vm.agentControlEnabled)]
            })]
        }
        guard Self.vmMethods.contains(request.method) else {
            throw ControlError(code: .invalidArgument, message: "Método desconocido: \(request.method)")
        }
        // Orden de comprobación: VM existe → control permitido → (estado) → argumentos.
        guard let vmName = request.params["vm"]?.stringValue else {
            throw ControlError(code: .invalidArgument, message: "Falta el parámetro «vm»")
        }
        let vm = try controllable(vmName)
        let params = JSONValue.object(request.params)

        switch request.method {
        case "start_vm":
            if vm.state != .running { try await vm.start() }
            return ["state": .string(vm.state.rawValue)]

        case "stop_vm":
            let force = try params.decode(as: StopParams.self).force ?? false
            if vm.state.isActive { try await vm.stop(force: force) }
            return ["state": .string(vm.state.rawValue)]

        case "screenshot":
            try requireRunning(vm)
            let frame = try await vm.capture()
            let geometry = CoordinateMapper.geometry(
                sourcePixelWidth: frame.image.width, sourcePixelHeight: frame.image.height,
                viewWidth: frame.metrics.width, viewHeight: frame.metrics.height)
            let png = try ScreenshotEncoder.png(from: frame.image, width: geometry.imageWidth, height: geometry.imageHeight)
            lastGeometry[vm.id] = geometry
            return ["image_png_base64": .string(png.base64EncodedString()),
                    "width": .number(Double(geometry.imageWidth)), "height": .number(Double(geometry.imageHeight)),
                    "scale": .number(geometry.scale)]

        case "click":
            try requireRunning(vm)
            let p = try params.decode(as: ClickParams.self)
            let count = p.count ?? 1
            guard count == 1 || count == 2 else { throw ControlError(code: .invalidArgument, message: "count debe ser 1 o 2") }
            let point = try await viewPoint(vm, p.x, p.y)
            return try await act(vm, .click(at: point, button: p.button ?? .left, count: count))

        case "drag":
            try requireRunning(vm)
            let p = try params.decode(as: DragParams.self)
            let from = try await viewPoint(vm, p.fromX, p.fromY)
            let to = try await viewPoint(vm, p.toX, p.toY)
            return try await act(vm, .drag(from: from, to: to))

        case "scroll":
            try requireRunning(vm)
            let p = try params.decode(as: ScrollParams.self)
            let point = try await viewPoint(vm, p.x, p.y)
            return try await act(vm, .scroll(at: point, dx: p.dx, dy: p.dy))

        case "type_text":
            try requireRunning(vm)
            let p = try params.decode(as: TextParams.self)
            return try await act(vm, .keys(try KeyMap.strokes(forText: p.text)))

        case "key":
            try requireRunning(vm)
            let p = try params.decode(as: KeyParams.self)
            return try await act(vm, .keys([try KeyMap.stroke(forCombo: p.combo)]))

        default:
            throw ControlError(code: .invalidArgument, message: "Método desconocido: \(request.method)")
        }
    }

    // MARK: Ayudantes

    func find(_ name: String) throws -> any VMControlling {
        let match = directory.allVMs().first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame
        }
        guard let match else { throw ControlError(code: .vmNotFound, message: "No existe una VM «\(name)». Usa list_vms.") }
        return match
    }

    func controllable(_ name: String) throws -> any VMControlling {
        let vm = try find(name)
        guard vm.agentControlEnabled else {
            throw ControlError(code: .agentControlDisabled,
                               message: "La VM «\(vm.name)» no tiene activado «Permitir control de agente». Pide al usuario que lo active en su ventana.")
        }
        return vm
    }

    func requireRunning(_ vm: any VMControlling) throws {
        guard vm.state == .running else {
            throw ControlError(code: .vmNotRunning, message: "La VM «\(vm.name)» está «\(vm.state.rawValue)». Usa start_vm.")
        }
    }

    /// Usa el espacio de la última captura (o el que tendría una captura ahora) y el tamaño actual de la vista.
    func viewPoint(_ vm: any VMControlling, _ x: Double, _ y: Double) async throws -> CGPoint {
        let metrics = try await vm.viewMetrics()
        let shot = lastGeometry[vm.id] ?? CoordinateMapper.geometry(
            sourcePixelWidth: Int(metrics.width * metrics.backingScale), sourcePixelHeight: Int(metrics.height * metrics.backingScale),
            viewWidth: metrics.width, viewHeight: metrics.height)
        let current = CaptureGeometry(imageWidth: shot.imageWidth, imageHeight: shot.imageHeight,
                                      viewWidth: metrics.width, viewHeight: metrics.height)
        return try CoordinateMapper.viewPoint(x: x, y: y, in: current, viewIsFlipped: metrics.isFlipped)
    }

    func act(_ vm: any VMControlling, _ action: InputAction) async throws -> JSONValue {
        try await vm.perform(action)
        onAgentActivity(vm.id)
        return ["ok": true]
    }

    static func controlError(from error: any Error) -> ControlError {
        switch error {
        case let error as ControlError: error
        case let error as CoordinateError: ControlError(code: .invalidArgument, message: error.description)
        case let error as KeyMapError: ControlError(code: .invalidArgument, message: error.description)
        case let error as DecodingError: ControlError(code: .invalidArgument, message: describe(error))
        default: ControlError(code: .internalError, message: error.localizedDescription)
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, _): return "Falta el parámetro «\(key.stringValue)»"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "Tipo inválido en el parámetro «\(path(context))»"
        case .dataCorrupted(let context): return "Parámetro inválido «\(path(context))»: \(context.debugDescription)"
        @unknown default: return "Parámetros inválidos"
        }
    }
}
