import ControlProtocol
import Foundation
import MCP
import MCPBridge

// Si Claude Code cierra la tubería, una escritura no debe matar el proceso.
signal(SIGPIPE, SIG_IGN)

let socketPath = ControlPaths.socketPath
let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(filePath: CommandLine.arguments[0])
let launcher = AppLauncher(socketPath: socketPath, appBundle: AppLauncher.appBundle(forExecutable: executable))
let bridge = Bridge(client: ControlClient(path: socketPath), launcher: launcher)

let server = Server(name: "vmbox", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
await bridge.register(on: server)
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
