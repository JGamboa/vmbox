import ControlProtocol
import Foundation
import MCP

public protocol ControlCalling: Sendable {
    func call(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue
}

extension ControlClient: ControlCalling {}

public protocol AppLaunching: Sendable {
    /// Abre VMBox si hace falta y espera a que el socket acepte conexiones.
    func ensureRunning() async throws
}

/// Traductor MCP → socket de control. Sin lógica de negocio: valida el nombre de la herramienta,
/// reenvía los argumentos tal cual y convierte el resultado. Nunca lanza.
public struct Bridge: Sendable {
    let client: any ControlCalling
    let launcher: any AppLaunching

    public init(client: any ControlCalling, launcher: any AppLaunching) {
        self.client = client
        self.launcher = launcher
    }

    public func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.tools) }
        await server.withMethodHandler(CallTool.self) { params in await self.handle(params) }
    }

    public func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard let spec = ToolCatalog.spec(named: params.name) else {
            return Self.errorResult(ControlError(code: .invalidArgument, message: "Herramienta desconocida: \(params.name)"))
        }
        do {
            let arguments = try Self.convert(params.arguments ?? [:])
            let value = try await callLaunchingIfNeeded(method: spec.name, params: arguments, timeout: spec.timeout(arguments))
            return Self.successResult(value)
        } catch let error as ControlError {
            return Self.errorResult(error)
        } catch {
            return Self.errorResult(ControlError(code: .internalError, message: "\(error)"))
        }
    }

    func callLaunchingIfNeeded(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        do {
            return try await client.call(method: method, params: params, timeout: timeout)
        } catch let error as ControlError where error.code == .appUnavailable {
            try await launcher.ensureRunning()
            return try await client.call(method: method, params: params, timeout: timeout)
        }
    }

    static func convert(_ arguments: [String: Value]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(arguments))
    }

    static func successResult(_ value: JSONValue) -> CallTool.Result {
        var content: [Tool.Content] = []
        var rest = value
        if case .object(var object) = value, case .string(let base64)? = object["image_png_base64"] {
            object.removeValue(forKey: "image_png_base64")
            content.append(.image(data: base64, mimeType: "image/png", annotations: nil, _meta: nil))
            rest = .object(object)
        }
        content.append(.text(text: rest.prettyString, annotations: nil, _meta: nil))
        return CallTool.Result(content: content, isError: false)
    }

    static func errorResult(_ error: ControlError) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "\(error.code.rawValue): \(error.message)", annotations: nil, _meta: nil)], isError: true)
    }
}
