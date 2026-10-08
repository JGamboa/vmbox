import Foundation

public enum VMState: String, Codable, Sendable {
    case stopped, starting, running, paused, stopping, error

    public var isActive: Bool { self == .starting || self == .running || self == .paused || self == .stopping }

    public var displayName: String {
        switch self {
        case .stopped: "Detenida"
        case .starting: "Iniciando"
        case .running: "En ejecución"
        case .paused: "En pausa"
        case .stopping: "Deteniendo"
        case .error: "Error"
        }
    }
}

public enum VMStateEvent: Equatable, Sendable {
    case startRequested, startSucceeded, pauseSucceeded, resumeSucceeded, stopRequested, stopAbandoned
}

public enum VMStateError: Error, Equatable, LocalizedError {
    case invalidTransition(from: VMState, event: VMStateEvent)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let state, event: _):
            return "Operación no válida: la VM está «\(state.displayName)»"
        }
    }
}

public struct VMStateMachine: Equatable, Sendable {
    public private(set) var state: VMState = .stopped
    public private(set) var lastError: String?

    public init() {}

    public mutating func apply(_ event: VMStateEvent) throws {
        let next: VMState? = switch (state, event) {
        case (.stopped, .startRequested), (.error, .startRequested): .starting
        case (.starting, .startSucceeded): .running
        case (.running, .pauseSucceeded): .paused
        case (.paused, .resumeSucceeded): .running
        case (.running, .stopRequested), (.paused, .stopRequested): .stopping
        case (.stopping, .stopAbandoned): .running
        default: nil
        }
        guard let next else { throw VMStateError.invalidTransition(from: state, event: event) }
        if event == .startRequested { lastError = nil }
        state = next
    }

    /// El invitado se apagó o la VM fue detenida a la fuerza.
    public mutating func markStopped() { state = .stopped }

    public mutating func fail(_ message: String) {
        state = .error
        lastError = message
    }
}
