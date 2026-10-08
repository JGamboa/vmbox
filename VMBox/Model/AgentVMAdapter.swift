import AgentControl
import ControlProtocol
import Foundation
import Virtualization
import VMCore

@MainActor
final class AgentVMAdapter: VMControlling {
    let instance: VMInstance
    unowned let model: AppModel

    init(instance: VMInstance, model: AppModel) {
        self.instance = instance
        self.model = model
    }

    var id: UUID { instance.id }
    var name: String { instance.config.name }
    var os: GuestOS { instance.config.os }
    var state: VMState { instance.state }
    var agentControlEnabled: Bool { instance.config.agentControlEnabled }

    func start() async throws {
        do {
            try await model.start(id)
        } catch AppError.macOSLimitReached {
            throw ControlError(code: .invalidArgument, message: AppError.macOSLimitReached.localizedDescription)
        }
    }

    func stop(force: Bool) async throws {
        do {
            try await model.stop(id, force: force)
        } catch VMInstanceError.stopTimedOut {
            throw ControlError(code: .timeout, message: "El invitado no se apagó en 30 s; reintenta con force=true.")
        }
    }

    func viewMetrics() async throws -> ViewMetrics {
        let view = try await ensureView()
        return ViewMetrics(width: view.bounds.width, height: view.bounds.height,
                           backingScale: Double(view.window?.backingScaleFactor ?? 2), isFlipped: view.isFlipped)
    }

    func capture() async throws -> CapturedFrame {
        let view = try await ensureView()
        guard let image = ViewCapture.capture(view) else {
            throw ControlError(code: .internalError, message: "No se pudo capturar la pantalla de la VM")
        }
        return CapturedFrame(image: image, metrics: try await viewMetrics())
    }

    func perform(_ action: InputAction) async throws {
        let view = try await ensureView()
        await ViewInputInjector(view: view).perform(action)
    }

    /// La VM solo se controla con ventana: si no existe, se abre y se espera la vista (hasta 4 s).
    private func ensureView() async throws -> VZVirtualMachineView {
        if let view = model.view(for: id), view.window != nil { return view }
        model.openVMWindow?(id)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if let view = model.view(for: id), view.window != nil { return view }
        }
        throw ControlError(code: .internalError, message: "No se pudo abrir la ventana de la VM")
    }
}
