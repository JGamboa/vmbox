import Foundation
import Observation
import Virtualization

public enum VMInstanceError: Error, LocalizedError {
    case notRunning
    case stopTimedOut
    case invalidStateForSnapshot(VMState)
    case busy

    public var errorDescription: String? {
        switch self {
        case .notRunning: "La VM no está en ejecución."
        case .stopTimedOut: "El invitado no se apagó a tiempo. Usa «Forzar apagado»."
        case .busy: "Hay un snapshot en curso; espera a que termine."
        case .invalidStateForSnapshot(let state): "No se puede crear un snapshot con la VM «\(state.displayName)»."
        }
    }
}

@MainActor
@Observable
public final class VMInstance: NSObject, Identifiable {
    public let id: UUID
    public let bundle: VMBundle
    public private(set) var config: VMConfig
    public private(set) var machine: VZVirtualMachine?
    public var diskUsageBytes: UInt64
    /// Resolución del invitado para el próximo arranque (la app la calcula según la pantalla).
    public var displayPlan: DisplayPlan = .fallback
    private var stateMachine = VMStateMachine()
    /// Estado de memoria a restaurar en el próximo `start()` (lo fija `restoreSnapshot`).
    public private(set) var pendingRestoreState: URL?
    /// Si la configuración actual admite guardar/restaurar memoria (se calcula al iniciar).
    private var saveRestoreSupported = false
    /// Evita que pause/stop/otro snapshot se intercalen con un snapshot o restauración en curso.
    private var snapshotInProgress = false

    public var snapshots: SnapshotStore { SnapshotStore(bundle: bundle) }

    public var state: VMState { stateMachine.state }
    public var lastError: String? { stateMachine.lastError }

    public init(bundle: VMBundle, config: VMConfig, diskUsageBytes: UInt64 = 0) {
        self.id = config.id
        self.bundle = bundle
        self.config = config
        self.diskUsageBytes = diskUsageBytes
        super.init()
    }

    /// Modifica y persiste `config.json`.
    public func updateConfig(_ mutate: (inout VMConfig) -> Void) throws {
        var updated = config
        mutate(&updated)
        try bundle.writeConfig(updated)
        config = updated
    }

    public func start() async throws {
        try stateMachine.apply(.startRequested)
        do {
            let configuration = try VMConfigurationBuilder.build(config: config, bundle: bundle, display: displayPlan)
            saveRestoreSupported = (try? configuration.validateSaveRestoreSupport()) != nil
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            machine = vm
            if let stateURL = pendingRestoreState {
                pendingRestoreState = nil
                do {
                    try await vm.restoreMachineStateFrom(url: stateURL)
                    try await vm.resume()
                } catch {
                    // Estado incompatible (p. ej. cambió la configuración): arranque en frío desde el disco restaurado.
                    let fresh = VZVirtualMachine(configuration: try VMConfigurationBuilder.build(config: config, bundle: bundle, display: displayPlan))
                    fresh.delegate = self
                    machine = fresh
                    try await fresh.start()
                }
            } else {
                try await vm.start()
            }
            try stateMachine.apply(.startSucceeded)
        } catch {
            machine = nil
            stateMachine.fail(error.localizedDescription)
            throw error
        }
    }

    public func pause() async throws {
        guard !snapshotInProgress else { throw VMInstanceError.busy }
        guard let machine, state == .running else { throw VMInstanceError.notRunning }
        try await machine.pause()
        try stateMachine.apply(.pauseSucceeded)
    }

    public func resume() async throws {
        guard let machine, state == .paused else { throw VMInstanceError.notRunning }
        try await machine.resume()
        try stateMachine.apply(.resumeSucceeded)
    }

    /// Pide al invitado que se apague; si no lo hace en `timeout`, fuerza (`force`) o lanza `stopTimedOut`.
    /// Una VM pausada se reanuda antes de pedir el apagado (salvo con `force`).
    public func stop(force: Bool = false, timeout: Duration = .seconds(30)) async throws {
        guard !snapshotInProgress else { throw VMInstanceError.busy }
        try await performStop(force: force, timeout: timeout)
    }

    /// Lógica de apagado sin la guarda de `snapshotInProgress` (la usa `restoreSnapshot`).
    private func performStop(force: Bool, timeout: Duration) async throws {
        guard let machine, state == .running || state == .paused else { return }
        if state == .paused && !force {
            try await machine.resume()
            try stateMachine.apply(.resumeSucceeded)
        }
        try stateMachine.apply(.stopRequested)
        do {
            if machine.canRequestStop {
                try machine.requestStop()
                let deadline = ContinuousClock.now + timeout
                while state == .stopping, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            try? stateMachine.apply(.stopAbandoned)
            throw error
        }
        guard state == .stopping else { return }
        if force {
            do {
                try await machine.stop()
            } catch {
                didStop(error: error)
                throw error
            }
            didStop(error: nil)
        } else {
            try stateMachine.apply(.stopAbandoned)
            throw VMInstanceError.stopTimedOut
        }
    }

    /// Detenida: clona el disco. Encendida: pausa, guarda memoria (si se admite), clona y reanuda.
    public func createSnapshot(named name: String) async throws -> SnapshotInfo {
        guard !snapshotInProgress else { throw VMInstanceError.busy }
        snapshotInProgress = true
        defer { snapshotInProgress = false }
        let needed = (state == .running || state == .paused ? config.memoryBytes : 0) + .gib
        try DiskSpace.ensure(needed, available: DiskSpace.available(at: bundle.url))
        switch state {
        case .stopped, .error:
            return try await snapshots.create(name: name, includesMemory: false)
        case .paused:
            guard let machine else { throw VMInstanceError.notRunning }
            return try await snapshots.create(name: name, includesMemory: saveRestoreSupported) { url in
                try await machine.saveMachineStateTo(url: url)
            }
        case .running:
            guard let machine else { throw VMInstanceError.notRunning }
            try await machine.pause()
            try stateMachine.apply(.pauseSucceeded)
            do {
                let info = try await snapshots.create(name: name, includesMemory: saveRestoreSupported) { url in
                    try await machine.saveMachineStateTo(url: url)
                }
                try await machine.resume()
                try stateMachine.apply(.resumeSucceeded)
                return info
            } catch {
                if state == .paused {
                    try? await machine.resume()
                    try? stateMachine.apply(.resumeSucceeded)
                }
                throw error
            }
        case .starting, .stopping:
            throw VMInstanceError.invalidStateForSnapshot(state)
        }
    }

    /// Detiene la VM (forzado), restaura disco/NVRAM y deja pendiente la memoria para el próximo `start()`.
    public func restoreSnapshot(named name: String) async throws {
        guard !snapshotInProgress else { throw VMInstanceError.busy }
        snapshotInProgress = true
        defer { snapshotInProgress = false }
        if state == .starting || state == .stopping { throw VMInstanceError.invalidStateForSnapshot(state) }
        let info = try snapshots.info(name)
        if state == .running || state == .paused {
            try await performStop(force: true, timeout: .seconds(10))
        }
        pendingRestoreState = nil
        try snapshots.restoreFiles(name)
        pendingRestoreState = info.includesMemory ? try snapshots.memoryStateURL(for: name) : nil
    }

    private func didStop(error: (any Error)?) {
        machine = nil
        if let error {
            stateMachine.fail(error.localizedDescription)
        } else {
            stateMachine.markStopped()
        }
    }
}

extension VMInstance: VZVirtualMachineDelegate {
    // VZVirtualMachine se crea con la cola principal, así que los callbacks llegan en el hilo principal.
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let source = ObjectIdentifier(virtualMachine)
        MainActor.assumeIsolated {
            guard machine.map(ObjectIdentifier.init) == source else { return }
            didStop(error: nil)
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let source = ObjectIdentifier(virtualMachine)
        MainActor.assumeIsolated {
            guard machine.map(ObjectIdentifier.init) == source else { return }
            didStop(error: error)
        }
    }
}
