import AgentControl
import Foundation
import Observation
import Virtualization
import VMCore

enum AppError: Error, LocalizedError {
    case macOSLimitReached
    case vmNotFound

    var errorDescription: String? {
        switch self {
        case .macOSLimitReached:
            "Apple permite como máximo \(StartPolicy.maxConcurrentMacOS) VMs macOS simultáneas. Detén una antes de iniciar otra."
        case .vmNotFound: "La VM no existe."
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let libraryPathKey = "libraryPath"

    let library: VMLibrary
    let downloader = Downloader()
    private(set) var vms: [VMInstance] = []
    private(set) var brokenBundles: [URL] = []
    var alertMessage: String?
    /// La escena lo instala para abrir ventanas de VM desde código que no es vista (p. ej. el agente).
    var openVMWindow: ((UUID) -> Void)?
    let mcpLog = MCPLog(fileURL: VMBoxPaths.mcpLog)
    private(set) var agentActivity: [UUID: Date] = [:]
    @ObservationIgnored private var views: [UUID: WeakView] = [:]
    @ObservationIgnored private var controlHost: ControlHost?

    init() {
        let root = UserDefaults.standard.string(forKey: Self.libraryPathKey)
            .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? VMLibrary.defaultRoot
        library = VMLibrary(root: root)
        reload()
        let host = ControlHost(model: self)
        do {
            try host.start()
        } catch {
            alertMessage = "El control de agentes no está disponible: \(error.localizedDescription)"
        }
        controlHost = host
    }

    /// Relee la biblioteca conservando las instancias existentes (y sus VMs en ejecución).
    func reload() {
        do {
            let listing = try library.list()
            let existing = Dictionary(vms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            vms = listing.entries.map { entry in
                if let instance = existing[entry.id] {
                    instance.diskUsageBytes = entry.diskUsageBytes
                    return instance
                }
                return VMInstance(bundle: entry.bundle, config: entry.config, diskUsageBytes: entry.diskUsageBytes)
            }
            brokenBundles = listing.broken
        } catch {
            alertMessage = "No se pudo leer la biblioteca: \(error.localizedDescription)"
        }
    }

    func register(view: VZVirtualMachineView, for id: UUID) { views[id] = WeakView(view) }

    func view(for id: UUID) -> VZVirtualMachineView? { views[id]?.view }

    func noteAgentActivity(_ id: UUID) { agentActivity[id] = .now }

    func isAgentActive(_ id: UUID, at date: Date = .now, within seconds: TimeInterval = 3) -> Bool {
        guard let last = agentActivity[id] else { return false }
        return date.timeIntervalSince(last) < seconds
    }

    func setAgentControl(_ id: UUID, _ enabled: Bool) {
        do {
            try instance(for: id)?.updateConfig { $0.agentControlEnabled = enabled }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func instance(for id: UUID) -> VMInstance? { vms.first { $0.id == id } }

    func start(_ id: UUID) async throws {
        guard let vm = instance(for: id) else { throw AppError.vmNotFound }
        guard vm.state != .running else { return }
        if vm.state == .paused { return try await vm.resume() }
        let running = vms.filter { $0.state.isActive && $0.id != id }.map(\.config.os)
        guard StartPolicy.check(starting: vm.config.os, running: running) == .ok else { throw AppError.macOSLimitReached }
        openVMWindow?(id)
        try await vm.start()
    }

    func stop(_ id: UUID, force: Bool) async throws {
        guard let vm = instance(for: id) else { throw AppError.vmNotFound }
        try await vm.stop(force: force)
    }

    func createVM(config: VMConfig, localFile: URL?, onPhase: @escaping @MainActor @Sendable (CreationPhase) -> Void) async throws {
        switch config.os {
        case .linux:
            let creator = LinuxVMCreator(library: library, downloader: downloader, cacheDir: VMBoxPaths.cache)
            _ = try await creator.create(config: config, localISO: localFile) { phase in
                Task { @MainActor in onPhase(phase) }
            }
        case .macOS:
            let creator = MacOSVMCreator(library: library, downloader: downloader, cacheDir: VMBoxPaths.cache)
            _ = try await creator.create(config: config, localIPSW: localFile, onPhase: onPhase)
        }
        reload()
    }

    /// Ejecuta una acción de UI y muestra el error, si lo hay, como alerta.
    func perform(_ action: @MainActor () async throws -> Void) async {
        do { try await action() } catch { alertMessage = error.localizedDescription }
    }

    func suggestedName(for os: GuestOS) -> String {
        let taken = Set(vms.map { $0.config.name.lowercased() })
        var name = os.displayName
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(os.displayName) \(n)"
            n += 1
        }
        return name
    }
}

final class WeakView {
    weak var view: VZVirtualMachineView?
    init(_ view: VZVirtualMachineView) { self.view = view }
}

extension AppModel: VMDirectory {
    func allVMs() -> [any VMControlling] { vms.map { AgentVMAdapter(instance: $0, model: self) } }
}
