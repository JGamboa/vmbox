import ControlProtocol
import Darwin
import Foundation

/// Abre VMBox (el .app que contiene a vmbox-mcp, o `open -a VMBox`) y espera el socket (spec: 15 s).
public struct AppLauncher: AppLaunching {
    public let socketPath: String
    public let appBundle: URL?
    public let timeout: Duration
    let open: @Sendable ([String]) throws -> Void
    let canConnect: @Sendable (String) -> Bool

    public init(socketPath: String, appBundle: URL?, timeout: Duration = .seconds(15),
                open: @escaping @Sendable ([String]) throws -> Void = AppLauncher.runOpen,
                canConnect: @escaping @Sendable (String) -> Bool = AppLauncher.probe) {
        self.socketPath = socketPath
        self.appBundle = appBundle
        self.timeout = timeout
        self.open = open
        self.canConnect = canConnect
    }

    public func ensureRunning() async throws {
        try open(appBundle.map { [$0.path] } ?? ["-a", "VMBox"])
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if canConnect(socketPath) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ControlError(code: .appUnavailable, message: "VMBox no respondió en \(timeout) tras abrirlo")
    }

    /// `…/VMBox.app/Contents/MacOS/vmbox-mcp` → `…/VMBox.app`.
    public static func appBundle(forExecutable executable: URL) -> URL? {
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    public static func runOpen(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControlError(code: .appUnavailable, message: "open \(arguments.joined(separator: " ")) falló (\(process.terminationStatus))")
        }
    }

    public static func probe(_ path: String) -> Bool {
        guard let fd = try? UnixSocket.connect(path: path) else { return false }
        Darwin.close(fd)
        return true
    }
}
