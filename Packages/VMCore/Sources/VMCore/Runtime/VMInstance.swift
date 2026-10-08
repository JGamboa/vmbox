import Foundation
import Observation
import Virtualization

public enum VMInstanceError: Error, LocalizedError {
    case notRunning
    case stopTimedOut

    public var errorDescription: String? {
        switch self {
        case .notRunning: "La VM no está en ejecución."
        case .stopTimedOut: "El invitado no se apagó a tiempo. Usa «Forzar apagado»."
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
    private var stateMachine = VMStateMachine()

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
            let vm = VZVirtualMachine(configuration: try VMConfigurationBuilder.build(config: config, bundle: bundle))
            vm.delegate = self
            machine = vm
            try await vm.start()
            try stateMachine.apply(.startSucceeded)
        } catch {
            machine = nil
            stateMachine.fail(error.localizedDescription)
            throw error
        }
    }

    public func pause() async throws {
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
