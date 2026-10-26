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
    /// Llamadas en curso por VM, para que `revoke` las corte.
    private var inFlight: [UUID: [Int: InFlightCall]] = [:]
    private var nextCallToken = 0
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
    struct SnapshotParams: Decodable { var vm: String; var name: String }
    struct RestoreParams: Decodable { var vm: String; var name: String; var confirm: Bool? }
    struct CommandParams: Decodable {
        var command: String; var timeoutS: Double?; var asRoot: Bool?
        enum CodingKeys: String, CodingKey { case command, timeoutS = "timeout_s", asRoot = "as_root" }
    }
    struct PathParams: Decodable { var path: String }
    struct WriteParams: Decodable { var path: String; var content: String }
    struct ClipboardParams: Decodable { var text: String }

    // MARK: Despacho

    /// Métodos que actúan sobre una VM (todos salvo list_vms). Las Fases 3 y 4 añaden los suyos.
    static let guestMethods: Set<String> = ["run_command", "read_file", "write_file", "clipboard_get", "clipboard_set"]
    static let vmMethods: Set<String> = Set(["start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key",
                                             "snapshot_create", "snapshot_list", "snapshot_restore"]).union(guestMethods)

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
        let result: JSONValue
        do {
            result = try await revocable(vm) { try await self.perform(request, on: vm) }
        } catch {
            _ = try controllable(vmName)
            throw error
        }
        // Si el control se retiró mientras la acción corría, el agente no recibe su resultado.
        _ = try controllable(vmName)
        return result
    }

    func perform(_ request: ControlRequest, on vm: any VMControlling) async throws -> JSONValue {
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
            try requireSize(frame.metrics)
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

        case "snapshot_create":
            let p = try params.decode(as: SnapshotParams.self)
            return Self.snapshotJSON(try await vm.createSnapshot(name: p.name))

        case "snapshot_list":
            return ["snapshots": .array(try vm.listSnapshots().map(Self.snapshotJSON))]

        case "snapshot_restore":
            let p = try params.decode(as: RestoreParams.self)
            guard p.confirm == true else {
                throw ControlError(code: .invalidArgument,
                                   message: "snapshot_restore exige confirm: true (detiene la VM y descarta su estado actual)")
            }
            try await vm.restoreSnapshot(name: p.name)
            return ["restored": .string(p.name), "state": .string(vm.state.rawValue)]

        case let method where Self.guestMethods.contains(method):
            try requireRunning(vm)
            var timeout = 30.0
            switch method {
            case "run_command":
                let p = try params.decode(as: CommandParams.self)
                guard !p.command.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ControlError(code: .invalidArgument, message: "Falta el parámetro «command»")
                }
                let seconds = p.timeoutS ?? 60
                guard seconds > 0, seconds <= 3600 else {
                    throw ControlError(code: .invalidArgument, message: "timeout_s debe ser mayor que 0 y como máximo 3600")
                }
                timeout = seconds + 10
            case "read_file":
                try Self.requireAbsolute(try params.decode(as: PathParams.self).path)
            case "write_file":
                try Self.requireAbsolute(try params.decode(as: WriteParams.self).path)
            case "clipboard_set":
                _ = try params.decode(as: ClipboardParams.self)
            default:
                break
            }
            var forwarded = request.params
            forwarded.removeValue(forKey: "vm")
            let result = try await vm.guestCall(method: method, params: forwarded, timeout: timeout)
            onAgentActivity(vm.id)
            return result

        default:
            throw ControlError(code: .invalidArgument, message: "Método desconocido: \(request.method)")
        }
    }

    static func requireAbsolute(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw ControlError(code: .invalidArgument, message: "path debe ser absoluta: \(path)")
        }
    }

    // MARK: Revocación

    private final class InFlightCall {
        let continuation: CheckedContinuation<JSONValue, any Error>
        var task: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<JSONValue, any Error>) { self.continuation = continuation }
    }

    /// Corta en el acto todas las llamadas en curso sobre la VM: cada una responde `agent_control_disabled`
    /// sin esperar a que termine su trabajo, y su Task se cancela (lo que cierra la conexión vsock con el
    /// guest-agent, que entonces mata el comando). La app lo llama al desactivar «Permitir control de agente».
    public func revoke(_ vmID: UUID) {
        guard let calls = inFlight.removeValue(forKey: vmID) else { return }
        for call in calls.values {
            call.task?.cancel()
            call.continuation.resume(throwing: ControlError(
                code: .agentControlDisabled,
                message: "El usuario retiró «Permitir control de agente» mientras la llamada estaba en curso; se canceló."))
        }
    }

    /// Número de llamadas en curso sobre la VM (para pruebas).
    public func inFlightCount(_ vmID: UUID) -> Int { inFlight[vmID]?.count ?? 0 }

    private func revocable(_ vm: any VMControlling, _ work: @escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue {
        let vmID = vm.id
        let token = nextCallToken
        nextCallToken += 1
        return try await withCheckedThrowingContinuation { continuation in
            let call = InFlightCall(continuation)
            inFlight[vmID, default: [:]][token] = call
            call.task = Task { @MainActor in
                let result: Result<JSONValue, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                // Si `revoke` ya respondió, el resultado se descarta.
                guard let call = self.inFlight[vmID]?.removeValue(forKey: token) else { return }
                if self.inFlight[vmID]?.isEmpty == true { self.inFlight.removeValue(forKey: vmID) }
                call.continuation.resume(with: result)
            }
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

    func requireSize(_ metrics: ViewMetrics) throws {
        guard metrics.width > 0, metrics.height > 0 else {
            throw ControlError(code: .internalError, message: "La vista de la VM aún no tiene tamaño")
        }
    }

    /// Usa el espacio de la última captura (o el que tendría una captura ahora) y el tamaño actual de la vista.
    func viewPoint(_ vm: any VMControlling, _ x: Double, _ y: Double) async throws -> CGPoint {
        let metrics = try await vm.viewMetrics()
        try requireSize(metrics)
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

    static func snapshotJSON(_ info: SnapshotInfo) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        return ["name": .string(info.name), "created_at": .string(formatter.string(from: info.createdAt)),
                "includes_memory": .bool(info.includesMemory)]
    }

    static func controlError(from error: any Error) -> ControlError {
        switch error {
        case let error as ControlError: error
        case let error as CoordinateError: ControlError(code: .invalidArgument, message: error.description)
        case let error as KeyMapError: ControlError(code: .invalidArgument, message: error.description)
        case let error as DecodingError: ControlError(code: .invalidArgument, message: describe(error))
        case let error as SnapshotError: ControlError(code: .invalidArgument, message: error.localizedDescription)
        case VMInstanceError.busy, VMInstanceError.invalidStateForSnapshot:
            ControlError(code: .invalidArgument, message: error.localizedDescription)
        case let error as DiskSpaceError: ControlError(code: .internalError, message: error.localizedDescription)
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
