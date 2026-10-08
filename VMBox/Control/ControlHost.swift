import AgentControl
import ControlProtocol
import Foundation

@MainActor
final class ControlHost {
    private let service: ControlService
    private var server: ControlServer?

    init(model: AppModel) {
        service = ControlService(directory: model, log: model.mcpLog)
        service.onAgentActivity = { [weak model] id in model?.noteAgentActivity(id) }
    }

    /// Borra un socket viejo y escucha en ~/Library/Application Support/VMBox/control.sock (0600).
    func start() throws {
        try FileManager.default.createDirectory(at: ControlPaths.appSupport, withIntermediateDirectories: true)
        let service = self.service
        let server = ControlServer(path: ControlPaths.socketPath) { request in await service.handle(request) }
        try server.start()
        self.server = server
    }
}
