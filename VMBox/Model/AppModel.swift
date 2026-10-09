import AgentControl
import AppKit
import ControlProtocol
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
    /// Pausar la VM al retirar el control de agente (por defecto, sí).
    static let pauseOnRevokeKey = "pauseOnAgentRevoke"

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
    /// VMs a las que se retiró el control en esta sesión: el bloqueo no depende de poder guardar config.json.
    @ObservationIgnored private var revokedControl: Set<UUID> = []
    /// VMs cuyo cancel_all no pudo completarse (estaban pausadas o el agente no respondió): se reintenta al reanudar.
    @ObservationIgnored private var pendingGuestCancel: Set<UUID> = []

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

    func isAgentControlRevoked(_ id: UUID) -> Bool { revokedControl.contains(id) }

    func setAgentControl(_ id: UUID, _ enabled: Bool) {
        guard let vm = instance(for: id) else { return }
        if enabled {
            revokedControl.remove(id)
        } else {
            // Primero se cierra la puerta (en memoria) y se cortan las llamadas en curso; luego se persiste.
            revokedControl.insert(id)
            controlHost?.revoke(id)
        }
        do {
            try vm.updateConfig { $0.agentControlEnabled = enabled }
        } catch {
            alertMessage = error.localizedDescription
        }
        if !enabled {
            Task { await contain(vm) }
        }
    }

    /// Detiene lo que el agente dejó en marcha: mata en el invitado todo lo que lanzó el guest-agent
    /// (cancel_all) y, si está activado (por defecto), pausa la VM para congelar cualquier otro efecto.
    private func contain(_ vm: VMInstance) async {
        var notes: [String] = []
        switch vm.state {
        case .running:
            if await cancelGuestProcesses(vm) {
                pendingGuestCancel.remove(vm.id)
            } else {
                pendingGuestCancel.insert(vm.id)
                notes.append("No se pudo confirmar que el guest-agent matara los procesos del agente; se reintentará al reanudar.")
            }
        case .paused:
            pendingGuestCancel.insert(vm.id)
            notes.append("La VM ya estaba pausada: al reanudarla se matarán primero los procesos que lanzó el agente.")
        default:
            return
        }
        let pauseOnRevoke = UserDefaults.standard.object(forKey: Self.pauseOnRevokeKey) as? Bool ?? true
        // Si el usuario volvió a activar el control mientras tanto, no se pausa.
        guard pauseOnRevoke, vm.state == .running, isAgentControlRevoked(vm.id) else {
            if !notes.isEmpty { alertMessage = notes.joined(separator: "\n\n") }
            return
        }
        do {
            try await vm.pause()
            alertMessage = (["Se pausó «\(vm.config.name)» al retirar el control de agente, para congelar cualquier efecto que siguiera en curso (procesos, escrituras en carpetas compartidas). Revisa la VM y reanúdala con «Iniciar» cuando quieras."] + notes)
                .joined(separator: "\n\n")
        } catch {
            alertMessage = (["No se pudo pausar «\(vm.config.name)» tras retirar el control de agente: \(error.localizedDescription). Detén la VM si quieres asegurarte de que no quede nada en curso."] + notes)
                .joined(separator: "\n\n")
        }
    }

    /// Pide al guest-agent que mate con SIGKILL todo lo que lanzó. Devuelve si lo confirmó sin supervivientes.
    private func cancelGuestProcesses(_ vm: VMInstance) async -> Bool {
        do {
            let result = try await GuestAgentClient(connector: VsockGuestConnector(instance: vm))
                .call(method: "cancel_all", params: [:], timeout: 5)
            return result["survivors"] == .array([])
        } catch {
            return false
        }
    }

    func instance(for id: UUID) -> VMInstance? { vms.first { $0.id == id } }

    /// Plan de pantalla según el área visible de la pantalla principal (`.fallback` si no hay).
    static func displayPlan(for os: GuestOS) -> DisplayPlan {
        guard let screen = NSScreen.main else { return .fallback }
        let size = screen.visibleFrame.size
        return DisplayPlan.make(for: os, screenWidthPoints: size.width, screenHeightPoints: size.height,
                                backingScale: screen.backingScaleFactor)
    }

    func start(_ id: UUID) async throws {
        guard let vm = instance(for: id) else { throw AppError.vmNotFound }
        guard vm.state != .running else { return }
        if vm.state == .paused {
            try await vm.resume()
            if pendingGuestCancel.contains(id), await cancelGuestProcesses(vm) { pendingGuestCancel.remove(id) }
            return
        }
        pendingGuestCancel.remove(id) // arranque en frío: no queda ningún proceso anterior
        let running = vms.filter { $0.state.isActive && $0.id != id }.map(\.config.os)
        guard StartPolicy.check(starting: vm.config.os, running: running) == .ok else { throw AppError.macOSLimitReached }
        vm.displayPlan = Self.displayPlan(for: vm.config.os)
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
