# VMBox — Fase 2: control de agente (socket, vmbox-mcp, pantalla y entrada)

> **Para agentes:** SUB-SKILL REQUERIDO: usa superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar este plan tarea por tarea. Los pasos usan casillas (`- [ ]`). Lee primero el índice [2026-10-08-vmbox-mvp-00-indice.md](2026-10-08-vmbox-mvp-00-indice.md) y los resultados del spike `docs/spikes/2026-10-fase0-resultados.md`. **Requisito:** Fase 1 terminada.

**Objetivo:** Claude Code, con `vmbox-mcp` registrado, puede listar, iniciar y detener VMs, capturar su pantalla y hacer clic, arrastrar, desplazar, escribir y pulsar combinaciones de teclas, solo en VMs con "Permitir control de agente" activado.

**Arquitectura:**
```
Claude Code ──stdio/MCP──▶ vmbox-mcp (MCPBridge) ──control.sock, JSON-RPC por líneas──▶ VMBox.app
                                                                     ControlServer → ControlService → AgentVMAdapter → VZVirtualMachineView
```
`ControlProtocol` (Foundation puro) define mensajes, framing y socket; `AgentControl` enruta cada método, valida permisos/argumentos y convierte coordenadas; `MCPBridge` define las herramientas MCP y reenvía sin lógica de negocio. La app aporta la captura y la inyección elegidas en la Fase 0.

**Stack:** Swift 6.3, POSIX sockets, `modelcontextprotocol/swift-sdk` 0.12.1, CoreGraphics/ImageIO, AppKit, XCTest, Python 3 (script de humo).

**Spec:** [docs/specs/2026-10-08-vmbox-design.md](../specs/2026-10-08-vmbox-design.md) §3.5, §4, §5.1, §5.2, §5.4, §6, §7.

## Estructura de archivos de esta fase

```
Packages/VMCore/Package.swift                         (+ ControlProtocol, AgentControl, MCPBridge, swift-sdk)
Packages/VMCore/Sources/ControlProtocol/
  JSONValue.swift  Messages.swift  ControlPaths.swift  LineChannel.swift  UnixSocket.swift  RPC.swift  ControlServer.swift  ControlClient.swift
Packages/VMCore/Sources/VMCore/Input/
  KeyMap.swift  CoordinateMapper.swift  ScreenshotEncoder.swift
Packages/VMCore/Sources/AgentControl/
  VMControlling.swift  ControlService.swift  MCPLog.swift
Packages/VMCore/Sources/MCPBridge/
  ToolCatalog.swift  Bridge.swift  AppLauncher.swift
Packages/VMCore/Tests/ControlProtocolTests/  Tests/AgentControlTests/  Tests/MCPBridgeTests/  Tests/VMCoreTests/(KeyMap, Coordinate)
vmbox-mcp/main.swift
VMBox/Control/ViewCapture.swift  ViewInputInjector.swift  ControlHost.swift
VMBox/Model/AgentVMAdapter.swift  (AppModel.swift modificado)
VMBox/Views/SettingsView.swift    (VMToolbar, VMWindowView, LibraryView, VMBoxApp modificados)
scripts/mcp_smoke.py
```

---

### Tarea 2.1: `ControlProtocol` — `JSONValue` y mensajes JSON-RPC

**Archivos:**
- Modificar: `Packages/VMCore/Package.swift`
- Crear: `Packages/VMCore/Sources/ControlProtocol/JSONValue.swift`, `Packages/VMCore/Sources/ControlProtocol/Messages.swift`, `Packages/VMCore/Sources/ControlProtocol/ControlPaths.swift`, `Packages/VMCore/Tests/ControlProtocolTests/MessagesTests.swift`

**Interfaces:**
- Produce:
  - `JSONValue` (`null, bool, number(Double), string, array, object`), literales, `subscript(key:)`, `stringValue`, `doubleValue`, `boolValue`, `objectValue`, `init(encoding:) throws`, `decode(as:) throws -> T`, `prettyString`.
  - `ControlErrorCode` (`agent_control_disabled`, `vm_not_found`, `vm_not_running`, `timeout`, `app_unavailable`, `invalid_argument`, `internal_error`).
  - `ControlError(code:message:)` (`Error`, `Codable`, `LocalizedError`).
  - `ControlRequest(id:method:params:)` con `params: [String: JSONValue]`; `RPCErrorObject { code: Int, message, data: ControlErrorCode }`; `ControlResponse` con `.success(id:result:)`, `.failure(id:error:)`, `get() throws -> JSONValue`.
  - `ControlPaths.appSupport: URL`, `ControlPaths.socketPath: String`.

- [ ] **Paso 1: añadir el target al paquete**

`Packages/VMCore/Package.swift` (reemplazo completo):

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
        .library(name: "ControlProtocol", targets: ["ControlProtocol"]),
    ],
    targets: [
        .target(name: "VMCore"),
        .target(name: "ControlProtocol"),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
        .testTarget(name: "ControlProtocolTests", dependencies: ["ControlProtocol"]),
    ]
)
```

- [ ] **Paso 2: tests que fallan**

`Packages/VMCore/Tests/ControlProtocolTests/MessagesTests.swift`:

```swift
import XCTest
@testable import ControlProtocol

final class MessagesTests: XCTestCase {
    func testDecodesMixedJSON() throws {
        let json = #"{"a":[1,true,null,"x",{"b":2.5}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value, ["a": [1, true, nil, "x", ["b": 2.5]]])
    }

    func testRoundTrip() throws {
        let value: JSONValue = ["vm": "Ubuntu", "x": 10, "ok": false, "list": [1, 2]]
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testDecodeIntoStruct() throws {
        struct Params: Decodable, Equatable { var vm: String; var x: Double; var count: Int? }
        let value: JSONValue = ["vm": "u", "x": 10.5, "count": 2]
        XCTAssertEqual(try value.decode(as: Params.self), Params(vm: "u", x: 10.5, count: 2))
        XCTAssertThrowsError(try JSONValue.object(["vm": "u"]).decode(as: Params.self))
    }

    func testEncodingInitializer() throws {
        struct S: Encodable { var name = "a"; var n = 3 }
        XCTAssertEqual(try JSONValue(encoding: S()), ["name": "a", "n": 3])
    }

    func testRequestShape() throws {
        let data = try JSONEncoder().encode(ControlRequest(id: 7, method: "list_vms", params: [:]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual(object["method"] as? String, "list_vms")
    }

    func testFailureCarriesCodeAsData() throws {
        let response = ControlResponse.failure(id: 3, error: ControlError(code: .vmNotFound, message: "no existe"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(error["data"] as? String, "vm_not_found")
        XCTAssertThrowsError(try response.get()) { thrown in
            XCTAssertEqual(thrown as? ControlError, ControlError(code: .vmNotFound, message: "no existe"))
        }
    }

    func testSuccessGet() throws {
        XCTAssertEqual(try ControlResponse.success(id: 1, result: ["ok": true]).get(), ["ok": true])
    }

    func testSocketPathIsInApplicationSupport() {
        XCTAssertTrue(ControlPaths.socketPath.hasSuffix("Library/Application Support/VMBox/control.sock"))
    }
}
```

- [ ] **Paso 3: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter MessagesTests`
Expected: FAIL de compilación (`cannot find 'JSONValue' in scope`)

- [ ] **Paso 4: implementación**

`Packages/VMCore/Sources/ControlProtocol/JSONValue.swift`:

```swift
import Foundation

/// Valor JSON arbitrario, `Sendable`, para parámetros y resultados del protocolo de control.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Valor JSON no reconocido") }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    public var prettyString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
```

`Packages/VMCore/Sources/ControlProtocol/Messages.swift`:

```swift
import Foundation

public enum ControlErrorCode: String, Codable, Sendable {
    case agentControlDisabled = "agent_control_disabled"
    case vmNotFound = "vm_not_found"
    case vmNotRunning = "vm_not_running"
    case timeout
    case appUnavailable = "app_unavailable"
    case invalidArgument = "invalid_argument"
    case internalError = "internal_error"
}

public struct ControlError: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: ControlErrorCode
    public var message: String

    public init(code: ControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "\(code.rawValue): \(message)" }
}

/// Petición JSON-RPC 2.0 (una por línea).
public struct ControlRequest: Codable, Equatable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int
    public var method: String
    public var params: [String: JSONValue]

    public init(id: Int, method: String, params: [String: JSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCErrorObject: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: ControlErrorCode
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int
    public var result: JSONValue?
    public var error: RPCErrorObject?

    public static func success(id: Int, result: JSONValue) -> ControlResponse {
        ControlResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: Int, error: ControlError) -> ControlResponse {
        ControlResponse(id: id, result: nil, error: RPCErrorObject(code: -32000, message: error.message, data: error.code))
    }

    public func get() throws -> JSONValue {
        if let error { throw ControlError(code: error.data, message: error.message) }
        return result ?? .null
    }
}
```

`Packages/VMCore/Sources/ControlProtocol/ControlPaths.swift`:

```swift
import Foundation

public enum ControlPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VMBox", directoryHint: .isDirectory)
    }

    public static var socketPath: String { appSupport.appending(path: "control.sock").path }
}
```

- [ ] **Paso 5: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter MessagesTests`
Expected: PASS (8 tests)

- [ ] **Paso 6: commit**

```bash
git add Packages/VMCore
git commit -m "feat(control): JSONValue y mensajes JSON-RPC del protocolo de control"
```

---

### Tarea 2.2: `LineChannel` y `UnixSocket`

**Archivos:**
- Crear: `Packages/VMCore/Sources/ControlProtocol/LineChannel.swift`, `Packages/VMCore/Sources/ControlProtocol/UnixSocket.swift`, `Packages/VMCore/Tests/ControlProtocolTests/LineChannelTests.swift`, `Packages/VMCore/Tests/ControlProtocolTests/UnixSocketTests.swift`

**Interfaces:**
- Produce:
  - `LineChannel(fd:)` (`@unchecked Sendable`): `readLine() throws -> Data?` (nil en EOF), `writeLine(_:) throws`, `setReadTimeout(_ seconds: Double)`, `close()`, `static let maxLineBytes = 64 MiB`. Activa `SO_NOSIGPIPE`.
  - `LineChannelError` (`timeout`, `lineTooLong`, `posix(Int32)`).
  - `UnixSocket.listen(path:) throws -> Int32` (reemplaza socket viejo, rechaza uno vivo, `chmod 0600`), `UnixSocket.connect(path:) throws -> Int32`.
  - `UnixSocketError` (`pathTooLong(String)`, `alreadyInUse(String)`, `posix(String, Int32)`).

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/ControlProtocolTests/LineChannelTests.swift`:

```swift
import Darwin
import XCTest
@testable import ControlProtocol

final class LineChannelTests: XCTestCase {
    func makePair() -> (LineChannel, LineChannel) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (LineChannel(fd: fds[0]), LineChannel(fd: fds[1]))
    }

    func testLinesArriveInOrder() throws {
        let (a, b) = makePair()
        defer { a.close(); b.close() }
        try a.writeLine(Data("uno".utf8))
        try a.writeLine(Data("dos".utf8))
        XCTAssertEqual(try b.readLine(), Data("uno".utf8))
        XCTAssertEqual(try b.readLine(), Data("dos".utf8))
    }

    func testLargeLine() throws {
        let (a, b) = makePair()
        defer { a.close(); b.close() }
        let big = Data(repeating: UInt8(ascii: "x"), count: 5 << 20)
        let writer = Thread { try? a.writeLine(big) }
        writer.start()
        XCTAssertEqual(try b.readLine()?.count, big.count)
    }

    func testEOFReturnsNil() throws {
        let (a, b) = makePair()
        a.close()
        XCTAssertNil(try b.readLine())
        b.close()
    }

    func testReadTimeout() throws {
        let (a, b) = makePair()
        defer { a.close(); b.close() }
        b.setReadTimeout(0.2)
        let start = Date()
        XCTAssertThrowsError(try b.readLine()) { error in
            XCTAssertEqual(error as? LineChannelError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Foco de revisión 3: escribir a un par cerrado lanza en vez de matar el proceso con SIGPIPE.
    func testWriteToClosedPeerThrows() throws {
        let (a, b) = makePair()
        b.close()
        XCTAssertThrowsError(try a.writeLine(Data("hola".utf8)))
        a.close()
    }
}
```

`Packages/VMCore/Tests/ControlProtocolTests/UnixSocketTests.swift`:

```swift
import Darwin
import XCTest
@testable import ControlProtocol

/// Ruta corta en /tmp: sun_path admite 103 bytes.
func makeSocketPath() -> String { "/tmp/vmbox-test-\(UUID().uuidString.prefix(8)).sock" }

final class UnixSocketTests: XCTestCase {
    func testRejectsTooLongPath() {
        let path = "/tmp/" + String(repeating: "a", count: 120)
        XCTAssertThrowsError(try UnixSocket.listen(path: path)) { error in
            XCTAssertEqual(error as? UnixSocketError, .pathTooLong(path))
        }
    }

    func testListenCreatesSocketWith0600() throws {
        let path = makeSocketPath()
        let fd = try UnixSocket.listen(path: path)
        defer { close(fd); unlink(path) }
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    /// Foco de revisión 3: un socket viejo (sin nadie escuchando) se reemplaza.
    func testStaleSocketIsReplaced() throws {
        let path = makeSocketPath()
        let old = try UnixSocket.listen(path: path)
        close(old) // el archivo queda, pero nadie escucha
        let fd = try UnixSocket.listen(path: path)
        defer { close(fd); unlink(path) }
        let client = try UnixSocket.connect(path: path)
        close(client)
    }

    /// Foco de revisión 3: no robar el socket de otra instancia viva.
    func testLiveSocketIsNotStolen() throws {
        let path = makeSocketPath()
        let fd = try UnixSocket.listen(path: path)
        defer { close(fd); unlink(path) }
        XCTAssertThrowsError(try UnixSocket.listen(path: path)) { error in
            XCTAssertEqual(error as? UnixSocketError, .alreadyInUse(path))
        }
    }

    func testConnectWithoutServerFails() {
        XCTAssertThrowsError(try UnixSocket.connect(path: makeSocketPath()))
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter "LineChannelTests|UnixSocketTests"`
Expected: FAIL de compilación (`cannot find 'LineChannel' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/ControlProtocol/LineChannel.swift`:

```swift
import Darwin
import Foundation

public enum LineChannelError: Error, Equatable {
    case timeout
    case lineTooLong
    case posix(Int32)
}

/// Mensajes delimitados por "\n" sobre un descriptor de socket bloqueante.
public final class LineChannel: @unchecked Sendable {
    public static let maxLineBytes = 64 << 20

    public let fd: Int32
    private var buffer = Data()
    private var scanned = 0
    private let lock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public func setReadTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Lee hasta "\n" (sin incluirlo). Devuelve `nil` en EOF si no quedan datos.
    public func readLine() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            if let newline = findNewline() {
                let line = buffer.prefix(newline)
                buffer = Data(buffer.dropFirst(newline + 1))
                scanned = 0
                return Data(line)
            }
            scanned = buffer.count
            guard buffer.count <= Self.maxLineBytes else { throw LineChannelError.lineTooLong }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer = Data(); scanned = 0 }
                return buffer
            }
            switch errno {
            case EINTR: continue
            case EAGAIN: throw LineChannelError.timeout
            default: throw LineChannelError.posix(errno)
            }
        }
    }

    /// Busca "\n" solo en los bytes aún no revisados (las capturas en base64 ocupan varios MB).
    private func findNewline() -> Int? {
        buffer.withUnsafeBytes { raw -> Int? in
            guard raw.count > scanned, let base = raw.baseAddress,
                  let hit = memchr(base + scanned, 0x0A, raw.count - scanned) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    public func writeLine(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LineChannelError.posix(errno)
                }
                offset += n
            }
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
```

`Packages/VMCore/Sources/ControlProtocol/UnixSocket.swift`:

```swift
import Darwin
import Foundation

public enum UnixSocketError: Error, Equatable, LocalizedError {
    case pathTooLong(String)
    case alreadyInUse(String)
    case posix(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "Ruta de socket demasiado larga: \(path)"
        case .alreadyInUse(let path): "Otra instancia de VMBox ya escucha en \(path)"
        case let .posix(call, code): "\(call) falló: \(String(cString: strerror(code)))"
        }
    }
}

public enum UnixSocket {
    static func address(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw UnixSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }

    /// Escucha en `path` con permisos 0600. Borra un socket viejo; falla si otro proceso ya escucha.
    public static func listen(path: String) throws -> Int32 {
        var addr = try address(path: path)
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? connect(path: path) {
                Darwin.close(probe)
                throw UnixSocketError.alreadyInUse(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.posix("socket", errno) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("bind", code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("chmod", code)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("listen", code)
        }
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        var addr = try address(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.posix("socket", errno) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.posix("connect", code)
        }
        return fd
    }
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter "LineChannelTests|UnixSocketTests"`
Expected: PASS (10 tests)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(control): canal por líneas y socket Unix 0600 sin robar instancias vivas"
```

---

### Tarea 2.3: `ControlServer`, `ControlClient` y `RPC`

**Archivos:**
- Crear: `Packages/VMCore/Sources/ControlProtocol/RPC.swift`, `Packages/VMCore/Sources/ControlProtocol/ControlServer.swift`, `Packages/VMCore/Sources/ControlProtocol/ControlClient.swift`, `Packages/VMCore/Tests/ControlProtocolTests/ControlServerTests.swift`

**Interfaces:**
- Consume: `LineChannel`, `UnixSocket`, mensajes de la Tarea 2.1.
- Produce:
  - `RPC.exchange(fd:method:params:timeout:) throws -> JSONValue` (una petición/respuesta; cierra el fd; EOF → `app_unavailable`; sin respuesta → `timeout`). La Fase 4 lo reutiliza con vsock.
  - `RPC.runOnThread(_:) async throws -> T` (trabajo bloqueante fuera del pool cooperativo).
  - `ControlServer(path:handler:)` con `start() throws`, `stop()`; `Handler = @Sendable (ControlRequest) async -> ControlResponse`.
  - `ControlClient(path:)` con `call(method:params:timeout:) async throws -> JSONValue` (sin servidor → `ControlError(.appUnavailable)`).

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/ControlProtocolTests/ControlServerTests.swift`:

```swift
import Darwin
import XCTest
@testable import ControlProtocol

final class ControlServerTests: XCTestCase {
    var path: String!
    var server: ControlServer?

    override func setUp() { path = makeSocketPath() }
    override func tearDown() { server?.stop() }

    func startServer(_ handler: @escaping ControlServer.Handler) throws {
        let server = ControlServer(path: path, handler: handler)
        try server.start()
        self.server = server
    }

    func testRoundTrip() async throws {
        try startServer { request in .success(id: request.id, result: ["echo": .string(request.method)]) }
        let result = try await ControlClient(path: path).call(method: "list_vms", params: [:], timeout: 5)
        XCTAssertEqual(result, ["echo": "list_vms"])
    }

    func testErrorPropagatesAsControlError() async throws {
        try startServer { request in .failure(id: request.id, error: ControlError(code: .vmNotRunning, message: "apagada")) }
        do {
            _ = try await ControlClient(path: path).call(method: "screenshot", params: ["vm": "u"], timeout: 5)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error, ControlError(code: .vmNotRunning, message: "apagada"))
        }
    }

    func testTimeout() async throws {
        try startServer { request in
            try? await Task.sleep(for: .seconds(2))
            return .success(id: request.id, result: nil)
        }
        do {
            _ = try await ControlClient(path: path).call(method: "lento", params: [:], timeout: 0.3)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .timeout)
        }
    }

    /// Foco de revisión 3: app no corriendo.
    func testNoServerIsAppUnavailable() async throws {
        do {
            _ = try await ControlClient(path: path).call(method: "list_vms", params: [:], timeout: 1)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .appUnavailable)
        }
    }

    func testInvalidJSONGetsErrorAndConnectionSurvives() throws {
        try startServer { request in .success(id: request.id, result: "ok") }
        let channel = LineChannel(fd: try UnixSocket.connect(path: path))
        defer { channel.close() }
        channel.setReadTimeout(5)
        try channel.writeLine(Data("esto no es json".utf8))
        let bad = try JSONDecoder().decode(ControlResponse.self, from: XCTUnwrap(channel.readLine()))
        XCTAssertEqual(bad.error?.data, .invalidArgument)
        try channel.writeLine(JSONEncoder().encode(ControlRequest(id: 2, method: "x", params: [:])))
        let good = try JSONDecoder().decode(ControlResponse.self, from: XCTUnwrap(channel.readLine()))
        XCTAssertEqual(good.result, "ok")
    }

    func testConcurrentCalls() async throws {
        try startServer { request in
            try? await Task.sleep(for: .milliseconds(50))
            return .success(id: request.id, result: .string(request.method))
        }
        let client = ControlClient(path: path)
        let results = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for i in 0..<10 { group.addTask { try await client.call(method: "m\(i)", params: [:], timeout: 5) } }
            return try await group.reduce(into: [JSONValue]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(results.compactMap(\.stringValue)), Set((0..<10).map { "m\($0)" }))
    }

    func testStopRemovesSocket() async throws {
        try startServer { request in .success(id: request.id, result: nil) }
        server?.stop()
        server = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter ControlServerTests`
Expected: FAIL de compilación (`cannot find 'ControlServer' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/ControlProtocol/RPC.swift`:

```swift
import Foundation

public enum RPC {
    /// Envía una petición por `fd`, espera una respuesta y cierra el descriptor.
    public static func exchange(fd: Int32, method: String, params: [String: JSONValue], timeout: Double) throws -> JSONValue {
        let channel = LineChannel(fd: fd)
        defer { channel.close() }
        channel.setReadTimeout(timeout)
        let request = ControlRequest(id: Int.random(in: 1...Int(Int32.max)), method: method, params: params)
        do {
            try channel.writeLine(JSONEncoder().encode(request))
        } catch {
            throw ControlError(code: .appUnavailable, message: "No se pudo enviar la petición: \(error)")
        }
        let line: Data?
        do {
            line = try channel.readLine()
        } catch LineChannelError.timeout {
            throw ControlError(code: .timeout, message: "Sin respuesta tras \(Int(timeout)) s (\(method))")
        }
        guard let line else { throw ControlError(code: .appUnavailable, message: "La conexión se cerró sin respuesta") }
        let response: ControlResponse
        do {
            response = try JSONDecoder().decode(ControlResponse.self, from: line)
        } catch {
            throw ControlError(code: .internalError, message: "Respuesta inválida: \(error)")
        }
        return try response.get()
    }

    /// Ejecuta trabajo bloqueante en un hilo propio para no ocupar el pool cooperativo.
    public static func runOnThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try work() }) }.start()
        }
    }

    /// Espera de forma bloqueante una operación async (solo desde hilos propios, nunca del pool).
    static func blockingAwait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

/// Caja mutable para pasar un resultado entre una Task y un hilo bloqueado en un semáforo.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
```

`Packages/VMCore/Sources/ControlProtocol/ControlServer.swift`:

```swift
import Darwin
import Foundation

/// Servidor del socket de control. Acepta con un DispatchSource y atiende cada conexión
/// en un hilo propio (lectura bloqueante, una respuesta por petición).
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "vmbox.control.accept")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let fd = try UnixSocket.listen(path: path)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            let handler = self.handler
            Thread { ControlServer.serve(fd: client, handler: handler) }.start()
        }
    }

    static func serve(fd: Int32, handler: @escaping Handler) {
        let channel = LineChannel(fd: fd)
        defer { channel.close() }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        while let line = try? channel.readLine() {
            let response: ControlResponse
            if let request = try? decoder.decode(ControlRequest.self, from: line) {
                response = RPC.blockingAwait { await handler(request) }
            } else {
                response = .failure(id: 0, error: ControlError(code: .invalidArgument, message: "Mensaje JSON-RPC inválido"))
            }
            guard let data = try? encoder.encode(response), (try? channel.writeLine(data)) != nil else { return }
        }
    }
}
```

`Packages/VMCore/Sources/ControlProtocol/ControlClient.swift`:

```swift
import Foundation

/// Cliente del socket de control: una conexión por llamada.
public struct ControlClient: Sendable {
    public let path: String

    public init(path: String = ControlPaths.socketPath) {
        self.path = path
    }

    public func call(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        let path = self.path
        return try await RPC.runOnThread {
            let fd: Int32
            do {
                fd = try UnixSocket.connect(path: path)
            } catch {
                throw ControlError(code: .appUnavailable, message: "VMBox no está escuchando en \(path)")
            }
            return try RPC.exchange(fd: fd, method: method, params: params, timeout: timeout)
        }
    }
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter ControlProtocolTests`
Expected: PASS (todos los tests de ControlProtocol)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(control): servidor y cliente del socket de control"
```

---

### Tarea 2.4: `KeyMap` — texto y combinaciones a key codes

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Input/KeyMap.swift`, `Packages/VMCore/Tests/VMCoreTests/KeyMapTests.swift`

**Interfaces:**
- Produce: `KeyModifiers` (`shift`, `control`, `option`, `command`; `OptionSet`), `KeyStroke { keyCode: UInt16, modifiers: KeyModifiers, characters: String }`, `KeyMapError` (`unsupportedCharacters(String)`, `unknownKey(String)`, `emptyCombo`, `textTooLong(Int)`; `CustomStringConvertible` en español), `KeyMap.strokes(forText:) throws -> [KeyStroke]`, `KeyMap.stroke(forCombo:) throws -> KeyStroke`, `KeyMap.modifierKeyCodes: [KeyModifiers: UInt16]` (control 59, option 58, shift 56, command 55), `KeyMap.maxTextLength = 10_000`.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/KeyMapTests.swift`:

```swift
import XCTest
@testable import VMCore

final class KeyMapTests: XCTestCase {
    func testTextWithShiftAndReturn() throws {
        XCTAssertEqual(try KeyMap.strokes(forText: "Hi!\n"), [
            KeyStroke(keyCode: 4, modifiers: .shift, characters: "H"),
            KeyStroke(keyCode: 34, modifiers: [], characters: "i"),
            KeyStroke(keyCode: 18, modifiers: .shift, characters: "!"),
            KeyStroke(keyCode: 36, modifiers: [], characters: "\r"),
        ])
    }

    func testAllPrintableASCIIIsSupported() throws {
        let printable = String((32...126).map { Character(Unicode.Scalar($0)!) })
        XCTAssertEqual(try KeyMap.strokes(forText: printable + "\t").count, printable.count + 1)
    }

    /// Foco de revisión 1: texto no ASCII → error con los caracteres, sin teclear nada.
    func testNonASCIIIsRejectedListingCharacters() {
        XCTAssertThrowsError(try KeyMap.strokes(forText: "ñandú 🙂")) { error in
            XCTAssertEqual(error as? KeyMapError, .unsupportedCharacters("ñú🙂"))
            XCTAssertTrue("\(error)".contains("ñú🙂"))
        }
    }

    func testTextTooLong() {
        XCTAssertThrowsError(try KeyMap.strokes(forText: String(repeating: "a", count: 10_001))) { error in
            XCTAssertEqual(error as? KeyMapError, .textTooLong(10_001))
        }
    }

    func testCombos() throws {
        XCTAssertEqual(try KeyMap.stroke(forCombo: "cmd+space"), KeyStroke(keyCode: 49, modifiers: .command, characters: " "))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "ctrl+alt+t"), KeyStroke(keyCode: 17, modifiers: [.control, .option], characters: "t"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "CTRL+C"), KeyStroke(keyCode: 8, modifiers: .control, characters: "c"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "return"), KeyStroke(keyCode: 36, modifiers: [], characters: "\r"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "shift+tab"), KeyStroke(keyCode: 48, modifiers: .shift, characters: "\t"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "cmd++"), KeyStroke(keyCode: 24, modifiers: [.command, .shift], characters: "+"))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "f5"), KeyStroke(keyCode: 96, modifiers: [], characters: ""))
        XCTAssertEqual(try KeyMap.stroke(forCombo: "super"), KeyStroke(keyCode: 55, modifiers: [], characters: ""))
        XCTAssertEqual(try KeyMap.stroke(forCombo: " Cmd + Shift + 4 "), KeyStroke(keyCode: 21, modifiers: [.command, .shift], characters: "4"))
    }

    func testBadCombos() {
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "")) { XCTAssertEqual($0 as? KeyMapError, .emptyCombo) }
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "ctrl+foo")) { XCTAssertEqual($0 as? KeyMapError, .unknownKey("foo")) }
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "hyper+a")) { XCTAssertEqual($0 as? KeyMapError, .unknownKey("hyper")) }
        XCTAssertThrowsError(try KeyMap.stroke(forCombo: "ctrl+ñ")) { XCTAssertEqual($0 as? KeyMapError, .unknownKey("ñ")) }
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter KeyMapTests`
Expected: FAIL de compilación (`cannot find 'KeyMap' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/VMCore/Input/KeyMap.swift`:

```swift
import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyStroke: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    public var characters: String

    public init(keyCode: UInt16, modifiers: KeyModifiers, characters: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
    }
}

public enum KeyMapError: Error, Equatable, CustomStringConvertible {
    case unsupportedCharacters(String)
    case unknownKey(String)
    case emptyCombo
    case textTooLong(Int)

    public var description: String {
        switch self {
        case .unsupportedCharacters(let chars):
            "Caracteres no soportados con la distribución de teclado US: «\(chars)». Usa ASCII imprimible, \\n y \\t (o clipboard_set con el guest-agent)."
        case .unknownKey(let key): "Tecla o modificador desconocido: «\(key)»"
        case .emptyCombo: "La combinación está vacía"
        case .textTooLong(let count): "Texto demasiado largo (\(count) caracteres; máximo \(KeyMap.maxTextLength))"
        }
    }
}

/// Mapeo a key codes virtuales de macOS (kVK_*) para distribución US-ANSI.
/// La VM recibe códigos de tecla físicos: el invitado debe usar distribución US.
public enum KeyMap {
    public static let maxTextLength = 10_000

    public static let modifierKeyCodes: [KeyModifiers: UInt16] = [.control: 59, .option: 58, .shift: 56, .command: 55]

    static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, " ": 49, "`": 50,
    ]

    static let shifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    static let named: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static let namedCharacters: [UInt16: String] = [36: "\r", 48: "\t", 49: " ", 51: "\u{8}", 53: "\u{1b}"]

    static let modifierNames: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "super": .command, "win": .command, "meta": .command,
        "ctrl": .control, "control": .control, "alt": .option, "option": .option, "opt": .option, "shift": .shift,
    ]

    public static func strokes(forText text: String) throws -> [KeyStroke] {
        guard text.count <= maxTextLength else { throw KeyMapError.textTooLong(text.count) }
        var strokes: [KeyStroke] = []
        var unsupported = ""
        for character in text {
            if let stroke = stroke(forCharacter: character) {
                strokes.append(stroke)
            } else if !unsupported.contains(character) {
                unsupported.append(character)
            }
        }
        guard unsupported.isEmpty else { throw KeyMapError.unsupportedCharacters(unsupported) }
        return strokes
    }

    static func stroke(forCharacter character: Character) -> KeyStroke? {
        switch character {
        case "\n", "\r", "\r\n": return KeyStroke(keyCode: 36, modifiers: [], characters: "\r")
        case "\t": return KeyStroke(keyCode: 48, modifiers: [], characters: "\t")
        default: break
        }
        if let code = unshifted[character] {
            return KeyStroke(keyCode: code, modifiers: [], characters: String(character))
        }
        if character.isASCII, character.isUppercase, let lower = character.lowercased().first, let code = unshifted[lower] {
            return KeyStroke(keyCode: code, modifiers: .shift, characters: String(character))
        }
        if let base = shifted[character], let code = unshifted[base] {
            return KeyStroke(keyCode: code, modifiers: .shift, characters: String(character))
        }
        return nil
    }

    /// Formato: modificadores y tecla separados por "+", p. ej. "cmd+space", "ctrl+alt+t", "cmd++", "super".
    public static func stroke(forCombo combo: String) throws -> KeyStroke {
        var spec = combo.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { throw KeyMapError.emptyCombo }
        let keyPart: String
        if spec == "+" {
            keyPart = "+"
            spec = ""
        } else if spec.hasSuffix("++") {
            keyPart = "+"
            spec = String(spec.dropLast(2))
        } else if let plus = spec.range(of: "+", options: .backwards) {
            keyPart = spec[plus.upperBound...].trimmingCharacters(in: .whitespaces)
            spec = String(spec[..<plus.lowerBound])
        } else {
            keyPart = spec
            spec = ""
        }

        var modifiers: KeyModifiers = []
        for name in spec.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
            guard let modifier = modifierNames[name] else { throw KeyMapError.unknownKey(name) }
            modifiers.insert(modifier)
        }

        let lowered = keyPart.lowercased()
        if let code = named[lowered] {
            return KeyStroke(keyCode: code, modifiers: modifiers, characters: namedCharacters[code] ?? "")
        }
        if let modifier = modifierNames[lowered], let code = modifierKeyCodes[modifier] {
            return KeyStroke(keyCode: code, modifiers: modifiers, characters: "")
        }
        guard keyPart.count == 1, let character = keyPart.first else { throw KeyMapError.unknownKey(keyPart) }
        let base: Character = character.isASCII && character.isLetter ? Character(character.lowercased()) : character
        guard let stroke = stroke(forCharacter: base) else { throw KeyMapError.unknownKey(keyPart) }
        return KeyStroke(keyCode: stroke.keyCode, modifiers: modifiers.union(stroke.modifiers), characters: stroke.characters)
    }
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter KeyMapTests`
Expected: PASS (6 tests)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): mapeo de texto y combinaciones a key codes US"
```

---

### Tarea 2.5: Coordenadas captura→vista y codificación de capturas

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Input/CoordinateMapper.swift`, `Packages/VMCore/Sources/VMCore/Input/ScreenshotEncoder.swift`, `Packages/VMCore/Tests/VMCoreTests/CoordinateMapperTests.swift`

**Interfaces:**
- Produce: `CaptureGeometry { imageWidth: Int, imageHeight: Int, viewWidth: Double, viewHeight: Double; scale: Double }`, `CoordinateMapper.maxImageWidth = 1280`, `CoordinateMapper.geometry(sourcePixelWidth:sourcePixelHeight:viewWidth:viewHeight:) -> CaptureGeometry`, `CoordinateMapper.viewPoint(x:y:in:viewIsFlipped:) throws -> CGPoint`, `CoordinateError.outOfBounds(x:y:width:height:)` (`CustomStringConvertible`), `ScreenshotEncoder.png(from:width:height:) throws -> Data`.

**Nota del spike:** si `docs/spikes/2026-10-fase0-resultados.md` registró que la captura **no** cubre exactamente la vista (bandas/letterbox), detenerse y consultar antes de esta tarea: el mapeo de abajo supone que la imagen capturada corresponde a todo `view.bounds`.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/CoordinateMapperTests.swift`:

```swift
import CoreGraphics
import ImageIO
import XCTest
@testable import VMCore

final class CoordinateMapperTests: XCTestCase {
    func testRetinaCaptureIsScaledTo1280() {
        let g = CoordinateMapper.geometry(sourcePixelWidth: 2560, sourcePixelHeight: 1600, viewWidth: 1280, viewHeight: 800)
        XCTAssertEqual(g, CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 1280, viewHeight: 800))
        XCTAssertEqual(g.scale, 1)
    }

    func testSmallCaptureIsNotUpscaled() {
        let g = CoordinateMapper.geometry(sourcePixelWidth: 1000, sourcePixelHeight: 500, viewWidth: 500, viewHeight: 250)
        XCTAssertEqual(g.imageWidth, 1000)
        XCTAssertEqual(g.imageHeight, 500)
        XCTAssertEqual(g.scale, 2)
    }

    func testMapsTopLeftOriginToAppKitPoint() throws {
        let g = CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 1280, viewHeight: 800)
        XCTAssertEqual(try CoordinateMapper.viewPoint(x: 100, y: 50, in: g, viewIsFlipped: false), CGPoint(x: 100, y: 750))
        XCTAssertEqual(try CoordinateMapper.viewPoint(x: 100, y: 50, in: g, viewIsFlipped: true), CGPoint(x: 100, y: 50))
    }

    /// Foco de revisión 2: tras redimensionar, el punto cae en el mismo lugar relativo.
    func testMapsIntoSmallerView() throws {
        let g = CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 640, viewHeight: 400)
        XCTAssertEqual(try CoordinateMapper.viewPoint(x: 100, y: 50, in: g, viewIsFlipped: false), CGPoint(x: 50, y: 375))
    }

    /// Foco de revisión 2: fuera de la captura → error.
    func testOutOfBounds() {
        let g = CaptureGeometry(imageWidth: 1280, imageHeight: 800, viewWidth: 1280, viewHeight: 800)
        for (x, y) in [(1280.0, 10.0), (-1, 10), (10, 800), (.nan, 1), (.infinity, 1)] {
            XCTAssertThrowsError(try CoordinateMapper.viewPoint(x: x, y: y, in: g, viewIsFlipped: false), "\(x),\(y)") { error in
                XCTAssertTrue("\(error)".contains("1280×800"))
            }
        }
    }

    func testEncodesScaledPNG() throws {
        let ctx = CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
        let png = try ScreenshotEncoder.png(from: ctx.makeImage()!, width: 1280, height: 800)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1280)
        XCTAssertEqual(image.height, 800)
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter CoordinateMapperTests`
Expected: FAIL de compilación (`cannot find 'CoordinateMapper' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/VMCore/Input/CoordinateMapper.swift`:

```swift
import CoreGraphics
import Foundation

/// Espacio de la captura entregada al agente y tamaño de la vista a la que se mapea.
public struct CaptureGeometry: Codable, Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var viewWidth: Double
    public var viewHeight: Double

    public init(imageWidth: Int, imageHeight: Int, viewWidth: Double, viewHeight: Double) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
    }

    /// Píxeles de captura por punto de vista.
    public var scale: Double { Double(imageWidth) / viewWidth }
}

public enum CoordinateError: Error, Equatable, CustomStringConvertible {
    case outOfBounds(x: Double, y: Double, width: Int, height: Int)

    public var description: String {
        switch self {
        case let .outOfBounds(x, y, width, height):
            "Coordenadas (\(x), \(y)) fuera de la última captura de \(width)×\(height) px"
        }
    }
}

public enum CoordinateMapper {
    public static let maxImageWidth = 1280

    public static func geometry(sourcePixelWidth: Int, sourcePixelHeight: Int, viewWidth: Double, viewHeight: Double) -> CaptureGeometry {
        let width = min(maxImageWidth, max(1, sourcePixelWidth))
        let height = max(1, Int((Double(sourcePixelHeight) * Double(width) / Double(max(1, sourcePixelWidth))).rounded()))
        return CaptureGeometry(imageWidth: width, imageHeight: height, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// (x, y) con origen arriba-izquierda en píxeles de la captura → punto de la vista.
    public static func viewPoint(x: Double, y: Double, in g: CaptureGeometry, viewIsFlipped: Bool) throws -> CGPoint {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(g.imageWidth), y < Double(g.imageHeight) else {
            throw CoordinateError.outOfBounds(x: x, y: y, width: g.imageWidth, height: g.imageHeight)
        }
        let viewX = x * g.viewWidth / Double(g.imageWidth)
        let fromTop = y * g.viewHeight / Double(g.imageHeight)
        return CGPoint(x: viewX, y: viewIsFlipped ? fromTop : g.viewHeight - fromTop)
    }
}
```

`Packages/VMCore/Sources/VMCore/Input/ScreenshotEncoder.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotEncoder {
    public struct EncodeError: Error {}

    public static func png(from image: CGImage, width: Int, height: Int) throws -> Data {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EncodeError() }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { throw EncodeError() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw EncodeError() }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError() }
        return data as Data
    }
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter CoordinateMapperTests`
Expected: PASS (6 tests)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): mapeo de coordenadas de captura y PNG ≤1280 px"
```

---

### Tarea 2.6: `AgentControl` — protocolo de VM controlable y `ControlService`

**Archivos:**
- Modificar: `Packages/VMCore/Package.swift`
- Crear: `Packages/VMCore/Sources/AgentControl/VMControlling.swift`, `Packages/VMCore/Sources/AgentControl/ControlService.swift`, `Packages/VMCore/Sources/AgentControl/MCPLog.swift` (solo el tipo de entrada en esta tarea; ver 2.7), `Packages/VMCore/Tests/AgentControlTests/Fakes.swift`, `Packages/VMCore/Tests/AgentControlTests/ControlServiceTests.swift`

**Interfaces:**
- Consume: `ControlRequest/ControlResponse/ControlError/JSONValue` (2.1), `KeyMap` (2.4), `CoordinateMapper/ScreenshotEncoder` (2.5), `VMState`, `GuestOS`.
- Produce:
  - `ViewMetrics { width, height, backingScale: Double; isFlipped: Bool }`, `CapturedFrame { image: CGImage; metrics: ViewMetrics }`, `MouseButton` (`left`, `right`), `InputAction` (`.click(at:button:count:)`, `.drag(from:to:)`, `.scroll(at:dx:dy:)`, `.keys([KeyStroke])`).
  - `@MainActor protocol VMControlling: AnyObject` — `id`, `name`, `os`, `state`, `agentControlEnabled`, `start()`, `stop(force:)`, `viewMetrics()`, `capture()`, `perform(_:)` (todas `async throws` salvo propiedades). La Fase 3 y la 4 añaden requisitos.
  - `@MainActor protocol VMDirectory: AnyObject { func allVMs() -> [any VMControlling] }`.
  - `@MainActor final class ControlService(directory:log:)` con `handle(_:) async -> ControlResponse` y `onAgentActivity: (UUID) -> Void`.
  - Resultados: `list_vms` → `{"vms":[{name, os, state, agentControlEnabled}]}`; `start_vm`/`stop_vm` → `{"state"}`; `screenshot` → `{"image_png_base64", "width", "height", "scale"}`; entrada → `{"ok": true}`.

- [ ] **Paso 1: target en el paquete**

En `Packages/VMCore/Package.swift`, añade a `products`:

```swift
        .library(name: "AgentControl", targets: ["AgentControl"]),
```

y a `targets`:

```swift
        .target(name: "AgentControl", dependencies: ["VMCore", "ControlProtocol"]),
        .testTarget(name: "AgentControlTests", dependencies: ["AgentControl"]),
```

- [ ] **Paso 2: fakes de prueba**

`Packages/VMCore/Tests/AgentControlTests/Fakes.swift`:

```swift
import AgentControl
import ControlProtocol
import CoreGraphics
import Foundation
import VMCore

@MainActor
final class FakeVM: VMControlling {
    let id = UUID()
    var name: String
    var os: GuestOS = .linux
    var state: VMState
    var agentControlEnabled: Bool
    var metrics = ViewMetrics(width: 1280, height: 800, backingScale: 2, isFlipped: false)
    var performed: [InputAction] = []
    var startCount = 0
    var stopForces: [Bool] = []

    init(name: String, state: VMState = .running, agentControlEnabled: Bool = true) {
        self.name = name
        self.state = state
        self.agentControlEnabled = agentControlEnabled
    }

    func start() async throws { startCount += 1; state = .running }
    func stop(force: Bool) async throws { stopForces.append(force); state = .stopped }
    func viewMetrics() async throws -> ViewMetrics { metrics }
    func perform(_ action: InputAction) async throws { performed.append(action) }

    func capture() async throws -> CapturedFrame {
        let width = Int(metrics.width * metrics.backingScale)
        let height = Int(metrics.height * metrics.backingScale)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedFrame(image: ctx.makeImage()!, metrics: metrics)
    }
}

@MainActor
final class FakeDirectory: VMDirectory {
    var vms: [FakeVM]
    init(_ vms: [FakeVM]) { self.vms = vms }
    func allVMs() -> [any VMControlling] { vms }
}
```

- [ ] **Paso 3: tests que fallan**

`Packages/VMCore/Tests/AgentControlTests/ControlServiceTests.swift`:

```swift
import AgentControl
import ControlProtocol
import CoreGraphics
import XCTest
import VMCore

@MainActor
final class ControlServiceTests: XCTestCase {
    var ubuntu: FakeVM!
    var locked: FakeVM!
    var service: ControlService!
    var activity: [UUID] = []

    override func setUp() async throws {
        ubuntu = FakeVM(name: "Ubuntu")
        locked = FakeVM(name: "Privada", agentControlEnabled: false)
        service = ControlService(directory: FakeDirectory([ubuntu, locked]))
        activity = []
        service.onAgentActivity = { [unowned self] in self.activity.append($0) }
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await service.handle(ControlRequest(id: 1, method: method, params: params))
    }

    /// Resultado de una llamada que debe tener éxito.
    func ok(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await call(method, params).get()
    }

    /// Código de error de una llamada que debe fallar.
    func failure(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlErrorCode? {
        await call(method, params).error?.data
    }

    func testListIncludesDisabledVMs() async throws {
        let result = try await ok("list_vms")
        guard case .array(let vms)? = result["vms"] else { return XCTFail("\(result)") }
        XCTAssertEqual(vms.count, 2)
        XCTAssertEqual(vms[1], ["name": "Privada", "os": "linux", "state": "running", "agentControlEnabled": false])
    }

    func testUnknownVM() async {
        let code = await failure("screenshot", ["vm": "nada"])
        XCTAssertEqual(code, .vmNotFound)
    }

    func testMatchesNameCaseInsensitively() async throws {
        _ = try await ok("click", ["vm": "ubuntu", "x": 1, "y": 1])
        XCTAssertEqual(ubuntu.performed.count, 1)
    }

    func testDisabledVMIsRejectedForEveryToolButList() async {
        for method in ["start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key"] {
            let code = await failure(method, ["vm": "Privada"])
            XCTAssertEqual(code, .agentControlDisabled, method)
        }
        XCTAssertTrue(locked.performed.isEmpty)
    }

    func testStoppedVMIsNotRunning() async {
        ubuntu.state = .stopped
        let screenshot = await failure("screenshot", ["vm": "Ubuntu"])
        let click = await failure("click", ["vm": "Ubuntu", "x": 1, "y": 1])
        XCTAssertEqual(screenshot, .vmNotRunning)
        XCTAssertEqual(click, .vmNotRunning)
    }

    func testStartAndStop() async throws {
        ubuntu.state = .stopped
        let started = try await ok("start_vm", ["vm": "Ubuntu"])
        XCTAssertEqual(started, ["state": "running"])
        XCTAssertEqual(ubuntu.startCount, 1)
        _ = try await ok("start_vm", ["vm": "Ubuntu"])
        XCTAssertEqual(ubuntu.startCount, 1, "start_vm es idempotente")
        let stopped = try await ok("stop_vm", ["vm": "Ubuntu", "force": true])
        XCTAssertEqual(stopped, ["state": "stopped"])
        XCTAssertEqual(ubuntu.stopForces, [true])
    }

    func testScreenshotReturnsPNGAtMost1280Wide() async throws {
        let result = try await ok("screenshot", ["vm": "Ubuntu"])
        XCTAssertEqual(result["width"], 1280)
        XCTAssertEqual(result["height"], 800)
        XCTAssertEqual(result["scale"], 1)
        let png = try XCTUnwrap(result["image_png_base64"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testClickMapsCoordinatesAndReportsActivity() async throws {
        _ = try await ok("screenshot", ["vm": "Ubuntu"])
        _ = try await ok("click", ["vm": "Ubuntu", "x": 100, "y": 50, "button": "right", "count": 2])
        XCTAssertEqual(ubuntu.performed, [.click(at: CGPoint(x: 100, y: 750), button: .right, count: 2)])
        XCTAssertEqual(activity, [ubuntu.id])
    }

    /// Foco de revisión 2: ventana redimensionada después de la captura.
    func testClickAfterResizeKeepsRelativePosition() async throws {
        _ = try await ok("screenshot", ["vm": "Ubuntu"])
        ubuntu.metrics = ViewMetrics(width: 640, height: 400, backingScale: 2, isFlipped: false)
        _ = try await ok("click", ["vm": "Ubuntu", "x": 100, "y": 50])
        XCTAssertEqual(ubuntu.performed, [.click(at: CGPoint(x: 50, y: 375), button: .left, count: 1)])
    }

    /// Foco de revisión 2: fuera de la última captura → invalid_argument sin clic.
    func testOutOfBoundsClickIsRejected() async throws {
        _ = try await ok("screenshot", ["vm": "Ubuntu"])
        let outside = await failure("click", ["vm": "Ubuntu", "x": 5000, "y": 10])
        let tripleClick = await failure("click", ["vm": "Ubuntu", "x": 10, "y": 10, "count": 3])
        XCTAssertEqual(outside, .invalidArgument)
        XCTAssertEqual(tripleClick, .invalidArgument)
        XCTAssertTrue(ubuntu.performed.isEmpty)
    }

    func testDragAndScroll() async throws {
        _ = try await ok("drag", ["vm": "Ubuntu", "from_x": 0, "from_y": 0, "to_x": 1279, "to_y": 799])
        _ = try await ok("scroll", ["vm": "Ubuntu", "x": 640, "y": 400, "dx": 0, "dy": 300])
        XCTAssertEqual(ubuntu.performed, [
            .drag(from: CGPoint(x: 0, y: 800), to: CGPoint(x: 1279, y: 1)),
            .scroll(at: CGPoint(x: 640, y: 400), dx: 0, dy: 300),
        ])
    }

    func testTypeTextAndKey() async throws {
        _ = try await ok("type_text", ["vm": "Ubuntu", "text": "ls\n"])
        _ = try await ok("key", ["vm": "Ubuntu", "combo": "cmd+space"])
        XCTAssertEqual(ubuntu.performed, [
            .keys([KeyStroke(keyCode: 37, modifiers: [], characters: "l"),
                   KeyStroke(keyCode: 1, modifiers: [], characters: "s"),
                   KeyStroke(keyCode: 36, modifiers: [], characters: "\r")]),
            .keys([KeyStroke(keyCode: 49, modifiers: .command, characters: " ")]),
        ])
    }

    /// Foco de revisión 1: no ASCII → invalid_argument y nada tecleado.
    func testNonASCIITextTypesNothing() async {
        let response = await call("type_text", ["vm": "Ubuntu", "text": "hola ñandú"])
        XCTAssertEqual(response.error?.data, .invalidArgument)
        XCTAssertTrue(response.error?.message.contains("ñú") ?? false)
        XCTAssertTrue(ubuntu.performed.isEmpty)
    }

    func testMissingAndMistypedParameters() async {
        let missing = await call("click", ["vm": "Ubuntu", "x": 1])
        XCTAssertEqual(missing.error?.data, .invalidArgument)
        XCTAssertTrue(missing.error?.message.contains("«y»") ?? false)
        let mistyped = await failure("click", ["vm": "Ubuntu", "x": "uno", "y": 1])
        let badCombo = await failure("key", ["vm": "Ubuntu", "combo": "ctrl+foo"])
        let unknownMethod = await failure("no_existe")
        let missingVM = await failure("screenshot")
        XCTAssertEqual(mistyped, .invalidArgument)
        XCTAssertEqual(badCombo, .invalidArgument)
        XCTAssertEqual(unknownMethod, .invalidArgument)
        XCTAssertEqual(missingVM, .invalidArgument)
    }
}
```

- [ ] **Paso 4: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter ControlServiceTests`
Expected: FAIL de compilación (`cannot find type 'VMControlling' in scope`)

- [ ] **Paso 5: implementación**

`Packages/VMCore/Sources/AgentControl/VMControlling.swift`:

```swift
import CoreGraphics
import Foundation
import VMCore

public struct ViewMetrics: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var backingScale: Double
    public var isFlipped: Bool

    public init(width: Double, height: Double, backingScale: Double, isFlipped: Bool) {
        self.width = width
        self.height = height
        self.backingScale = backingScale
        self.isFlipped = isFlipped
    }
}

public struct CapturedFrame: @unchecked Sendable {
    public var image: CGImage
    public var metrics: ViewMetrics

    public init(image: CGImage, metrics: ViewMetrics) {
        self.image = image
        self.metrics = metrics
    }
}

public enum MouseButton: String, Codable, Sendable { case left, right }

/// Acción de entrada ya traducida a puntos de la vista (AppKit).
public enum InputAction: Equatable, Sendable {
    case click(at: CGPoint, button: MouseButton, count: Int)
    case drag(from: CGPoint, to: CGPoint)
    case scroll(at: CGPoint, dx: Double, dy: Double)
    case keys([KeyStroke])
}

/// Lo que el servicio de control necesita de una VM. La app lo implementa sobre VMInstance + su vista.
@MainActor
public protocol VMControlling: AnyObject {
    var id: UUID { get }
    var name: String { get }
    var os: GuestOS { get }
    var state: VMState { get }
    var agentControlEnabled: Bool { get }
    /// Inicia la VM y abre su ventana.
    func start() async throws
    func stop(force: Bool) async throws
    /// Tamaño de la vista; abre la ventana si hace falta.
    func viewMetrics() async throws -> ViewMetrics
    func capture() async throws -> CapturedFrame
    func perform(_ action: InputAction) async throws
}

@MainActor
public protocol VMDirectory: AnyObject {
    func allVMs() -> [any VMControlling]
}
```

`Packages/VMCore/Sources/AgentControl/MCPLog.swift` (en esta tarea solo la entrada; la Tarea 2.7 añade la clase):

```swift
import Foundation

public struct MCPLogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var method: String
    public var vm: String?
    public var errorCode: String?
    public var durationMs: Int

    public var ok: Bool { errorCode == nil }

    public init(method: String, vm: String?, errorCode: String?, durationMs: Int) {
        self.method = method
        self.vm = vm
        self.errorCode = errorCode
        self.durationMs = durationMs
    }
}
```

`Packages/VMCore/Sources/AgentControl/ControlService.swift`:

```swift
import ControlProtocol
import CoreGraphics
import Foundation
import VMCore

/// Enruta cada método del socket de control: busca la VM, aplica permisos y estado,
/// valida argumentos, convierte coordenadas y delega en `VMControlling`.
@MainActor
public final class ControlService {
    private let directory: any VMDirectory
    private let log: MCPLog?
    private var lastGeometry: [UUID: CaptureGeometry] = [:]
    public var onAgentActivity: (UUID) -> Void = { _ in }

    public init(directory: any VMDirectory, log: MCPLog? = nil) {
        self.directory = directory
        self.log = log
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        let started = ContinuousClock.now
        let response: ControlResponse
        do {
            response = .success(id: request.id, result: try await dispatch(request))
        } catch {
            response = .failure(id: request.id, error: Self.controlError(from: error))
        }
        let elapsed = ContinuousClock.now - started
        log?.record(MCPLogEntry(
            method: request.method, vm: request.params["vm"]?.stringValue,
            errorCode: response.error?.data.rawValue,
            durationMs: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        ))
        return response
    }

    // MARK: Parámetros

    struct StopParams: Decodable { var vm: String; var force: Bool? }
    struct ClickParams: Decodable { var vm: String; var x: Double; var y: Double; var button: MouseButton?; var count: Int? }
    struct DragParams: Decodable {
        var vm: String; var fromX: Double; var fromY: Double; var toX: Double; var toY: Double
        enum CodingKeys: String, CodingKey { case vm, fromX = "from_x", fromY = "from_y", toX = "to_x", toY = "to_y" }
    }
    struct ScrollParams: Decodable { var vm: String; var x: Double; var y: Double; var dx: Double; var dy: Double }
    struct TextParams: Decodable { var vm: String; var text: String }
    struct KeyParams: Decodable { var vm: String; var combo: String }

    // MARK: Despacho

    /// Métodos que actúan sobre una VM (todos salvo list_vms). Las Fases 3 y 4 añaden los suyos.
    static let vmMethods: Set<String> = ["start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key"]

    func dispatch(_ request: ControlRequest) async throws -> JSONValue {
        if request.method == "list_vms" {
            return ["vms": .array(directory.allVMs().map { vm in
                ["name": .string(vm.name), "os": .string(vm.os.rawValue), "state": .string(vm.state.rawValue),
                 "agentControlEnabled": .bool(vm.agentControlEnabled)]
            })]
        }
        guard Self.vmMethods.contains(request.method) else {
            throw ControlError(code: .invalidArgument, message: "Método desconocido: \(request.method)")
        }
        // Orden de comprobación: VM existe → control permitido → (estado) → argumentos.
        guard let vmName = request.params["vm"]?.stringValue else {
            throw ControlError(code: .invalidArgument, message: "Falta el parámetro «vm»")
        }
        let vm = try controllable(vmName)
        let params = JSONValue.object(request.params)

        switch request.method {
        case "start_vm":
            if vm.state != .running { try await vm.start() }
            return ["state": .string(vm.state.rawValue)]

        case "stop_vm":
            let force = try params.decode(as: StopParams.self).force ?? false
            if vm.state.isActive { try await vm.stop(force: force) }
            return ["state": .string(vm.state.rawValue)]

        case "screenshot":
            try requireRunning(vm)
            let frame = try await vm.capture()
            let geometry = CoordinateMapper.geometry(
                sourcePixelWidth: frame.image.width, sourcePixelHeight: frame.image.height,
                viewWidth: frame.metrics.width, viewHeight: frame.metrics.height)
            let png = try ScreenshotEncoder.png(from: frame.image, width: geometry.imageWidth, height: geometry.imageHeight)
            lastGeometry[vm.id] = geometry
            return ["image_png_base64": .string(png.base64EncodedString()),
                    "width": .number(Double(geometry.imageWidth)), "height": .number(Double(geometry.imageHeight)),
                    "scale": .number(geometry.scale)]

        case "click":
            try requireRunning(vm)
            let p = try params.decode(as: ClickParams.self)
            let count = p.count ?? 1
            guard count == 1 || count == 2 else { throw ControlError(code: .invalidArgument, message: "count debe ser 1 o 2") }
            let point = try await viewPoint(vm, p.x, p.y)
            return try await act(vm, .click(at: point, button: p.button ?? .left, count: count))

        case "drag":
            try requireRunning(vm)
            let p = try params.decode(as: DragParams.self)
            let from = try await viewPoint(vm, p.fromX, p.fromY)
            let to = try await viewPoint(vm, p.toX, p.toY)
            return try await act(vm, .drag(from: from, to: to))

        case "scroll":
            try requireRunning(vm)
            let p = try params.decode(as: ScrollParams.self)
            let point = try await viewPoint(vm, p.x, p.y)
            return try await act(vm, .scroll(at: point, dx: p.dx, dy: p.dy))

        case "type_text":
            try requireRunning(vm)
            let p = try params.decode(as: TextParams.self)
            return try await act(vm, .keys(try KeyMap.strokes(forText: p.text)))

        case "key":
            try requireRunning(vm)
            let p = try params.decode(as: KeyParams.self)
            return try await act(vm, .keys([try KeyMap.stroke(forCombo: p.combo)]))

        default:
            throw ControlError(code: .invalidArgument, message: "Método desconocido: \(request.method)")
        }
    }

    // MARK: Ayudantes

    func find(_ name: String) throws -> any VMControlling {
        let match = directory.allVMs().first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame
        }
        guard let match else { throw ControlError(code: .vmNotFound, message: "No existe una VM «\(name)». Usa list_vms.") }
        return match
    }

    func controllable(_ name: String) throws -> any VMControlling {
        let vm = try find(name)
        guard vm.agentControlEnabled else {
            throw ControlError(code: .agentControlDisabled,
                               message: "La VM «\(vm.name)» no tiene activado «Permitir control de agente». Pide al usuario que lo active en su ventana.")
        }
        return vm
    }

    func requireRunning(_ vm: any VMControlling) throws {
        guard vm.state == .running else {
            throw ControlError(code: .vmNotRunning, message: "La VM «\(vm.name)» está «\(vm.state.rawValue)». Usa start_vm.")
        }
    }

    /// Usa el espacio de la última captura (o el que tendría una captura ahora) y el tamaño actual de la vista.
    func viewPoint(_ vm: any VMControlling, _ x: Double, _ y: Double) async throws -> CGPoint {
        let metrics = try await vm.viewMetrics()
        let shot = lastGeometry[vm.id] ?? CoordinateMapper.geometry(
            sourcePixelWidth: Int(metrics.width * metrics.backingScale), sourcePixelHeight: Int(metrics.height * metrics.backingScale),
            viewWidth: metrics.width, viewHeight: metrics.height)
        let current = CaptureGeometry(imageWidth: shot.imageWidth, imageHeight: shot.imageHeight,
                                      viewWidth: metrics.width, viewHeight: metrics.height)
        return try CoordinateMapper.viewPoint(x: x, y: y, in: current, viewIsFlipped: metrics.isFlipped)
    }

    func act(_ vm: any VMControlling, _ action: InputAction) async throws -> JSONValue {
        try await vm.perform(action)
        onAgentActivity(vm.id)
        return ["ok": true]
    }

    static func controlError(from error: any Error) -> ControlError {
        switch error {
        case let error as ControlError: error
        case let error as CoordinateError: ControlError(code: .invalidArgument, message: error.description)
        case let error as KeyMapError: ControlError(code: .invalidArgument, message: error.description)
        case let error as DecodingError: ControlError(code: .invalidArgument, message: describe(error))
        default: ControlError(code: .internalError, message: error.localizedDescription)
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, _): return "Falta el parámetro «\(key.stringValue)»"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "Tipo inválido en el parámetro «\(path(context))»"
        case .dataCorrupted(let context): return "Parámetro inválido «\(path(context))»: \(context.debugDescription)"
        @unknown default: return "Parámetros inválidos"
        }
    }
}
```

- [ ] **Paso 6: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter ControlServiceTests`
Expected: FAIL de compilación por `MCPLog` (la clase llega en 2.7). Para cerrar esta tarea en verde, añade temporalmente al final de `MCPLog.swift`:

```swift
@MainActor
public final class MCPLog {
    public func record(_ entry: MCPLogEntry) {}
}
```

Run de nuevo: Expected: PASS (14 tests). La Tarea 2.7 reemplaza esta clase mínima por la real.

- [ ] **Paso 7: commit**

```bash
git add Packages/VMCore
git commit -m "feat(agent): servicio de control con permisos, estado, coordenadas y entrada"
```

---

### Tarea 2.7: Log del MCP (memoria + archivo rotativo)

**Archivos:**
- Modificar: `Packages/VMCore/Sources/AgentControl/MCPLog.swift` (reemplaza la clase mínima)
- Crear: `Packages/VMCore/Tests/AgentControlTests/MCPLogTests.swift`

**Interfaces:**
- Produce: `@MainActor @Observable final class MCPLog(fileURL: URL?, maxBytes: Int = 1_000_000, keepInMemory: Int = 200)` con `recent: [MCPLogEntry]` y `record(_:)`. Archivo: una línea JSON por llamada; al superar `maxBytes` rota a `mcp.log.1` (sobrescribe).

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/AgentControlTests/MCPLogTests.swift`:

```swift
import AgentControl
import XCTest

@MainActor
final class MCPLogTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "mcplog-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func entry(_ n: Int) -> MCPLogEntry { MCPLogEntry(method: "click", vm: "u\(n)", errorCode: nil, durationMs: n) }

    func testRecordsInMemoryAndFile() throws {
        let file = dir.appending(path: "mcp.log")
        let log = MCPLog(fileURL: file)
        (0..<3).forEach { log.record(entry($0)) }
        XCTAssertEqual(log.recent.map(\.vm), ["u0", "u1", "u2"])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\"method\":\"click\""))
    }

    func testKeepsOnlyRecentInMemory() {
        let log = MCPLog(fileURL: nil, keepInMemory: 2)
        (0..<5).forEach { log.record(entry($0)) }
        XCTAssertEqual(log.recent.map(\.vm), ["u3", "u4"])
    }

    func testRotatesWhenTooBig() throws {
        let file = dir.appending(path: "mcp.log")
        let log = MCPLog(fileURL: file, maxBytes: 400)
        (0..<20).forEach { log.record(entry($0)) }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 400)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".1"))
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter MCPLogTests`
Expected: FAIL de compilación (`extra arguments at positions #1` en `MCPLog(fileURL:)`)

- [ ] **Paso 3: implementación**

Reemplaza la clase mínima de `Packages/VMCore/Sources/AgentControl/MCPLog.swift` (deja `MCPLogEntry` igual) por:

```swift
import Observation

@MainActor
@Observable
public final class MCPLog {
    public private(set) var recent: [MCPLogEntry] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let maxBytes: Int
    @ObservationIgnored private let keepInMemory: Int

    public init(fileURL: URL?, maxBytes: Int = 1_000_000, keepInMemory: Int = 200) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.keepInMemory = keepInMemory
    }

    public func record(_ entry: MCPLogEntry) {
        recent.append(entry)
        if recent.count > keepInMemory { recent.removeFirst(recent.count - keepInMemory) }
        if let fileURL { append(entry, to: fileURL) }
    }

    private func append(_ entry: MCPLogEntry, to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = ((try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if size > 0, size + line.count > maxBytes {
            let rotated = URL(filePath: fileURL.path + ".1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }
}
```

(Añade `import Foundation` arriba si el archivo no lo tiene ya.)

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter AgentControlTests`
Expected: PASS (17 tests)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(agent): log del MCP en memoria y archivo rotativo"
```

---

### Tarea 2.8: `MCPBridge` — catálogo de herramientas y puente MCP→socket

**Archivos:**
- Modificar: `Packages/VMCore/Package.swift`
- Crear: `Packages/VMCore/Sources/MCPBridge/ToolCatalog.swift`, `Packages/VMCore/Sources/MCPBridge/Bridge.swift`, `Packages/VMCore/Tests/MCPBridgeTests/Fakes.swift`, `Packages/VMCore/Tests/MCPBridgeTests/BridgeTests.swift`

**Interfaces:**
- Consume: `ControlClient`, `ControlServer`, `ControlError`, `JSONValue`; SDK MCP (`Server`, `Tool`, `CallTool`, `ListTools`, `Value`, `Client`, `InMemoryTransport`).
- Produce:
  - `protocol ControlCalling: Sendable { func call(method:params:timeout:) async throws -> JSONValue }` (con `extension ControlClient: ControlCalling {}`).
  - `protocol AppLaunching: Sendable { func ensureRunning() async throws }` (implementación real en 2.9).
  - `ToolSpec { name, description, properties: [String: Value], required: [String], timeout: @Sendable ([String: JSONValue]) -> Double; tool: Tool }`, `ToolCatalog.specs: [ToolSpec]`, `ToolCatalog.tools: [Tool]`, `ToolCatalog.spec(named:)`.
  - `Bridge(client:launcher:)` con `register(on: Server) async` y `handle(_: CallTool.Parameters) async -> CallTool.Result`.

- [ ] **Paso 1: dependencia y target**

`Packages/VMCore/Package.swift` (reemplazo completo):

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
        .library(name: "ControlProtocol", targets: ["ControlProtocol"]),
        .library(name: "AgentControl", targets: ["AgentControl"]),
        .library(name: "MCPBridge", targets: ["MCPBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "VMCore"),
        .target(name: "ControlProtocol"),
        .target(name: "AgentControl", dependencies: ["VMCore", "ControlProtocol"]),
        .target(name: "MCPBridge", dependencies: ["ControlProtocol", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
        .testTarget(name: "ControlProtocolTests", dependencies: ["ControlProtocol"]),
        .testTarget(name: "AgentControlTests", dependencies: ["AgentControl"]),
        .testTarget(name: "MCPBridgeTests", dependencies: ["MCPBridge", .product(name: "MCP", package: "swift-sdk")]),
    ]
)
```

Run: `swift package --package-path Packages/VMCore resolve`
Expected: resuelve `swift-sdk` 0.12.1 y sus dependencias sin errores.

- [ ] **Paso 2: fakes**

`Packages/VMCore/Tests/MCPBridgeTests/Fakes.swift`:

```swift
import ControlProtocol
import Foundation
@testable import MCPBridge

actor FakeControl: ControlCalling {
    var results: [Result<JSONValue, ControlError>]
    private(set) var calls: [(method: String, params: [String: JSONValue], timeout: Double)] = []

    init(_ results: [Result<JSONValue, ControlError>]) { self.results = results }

    func call(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        calls.append((method, params, timeout))
        return try results.removeFirst().get()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

struct FakeLauncher: AppLaunching {
    var succeeds = true
    let launches = Counter()

    func ensureRunning() async throws {
        launches.increment()
        if !succeeds { throw ControlError(code: .appUnavailable, message: "no arrancó") }
    }
}
```

- [ ] **Paso 3: tests que fallan**

`Packages/VMCore/Tests/MCPBridgeTests/BridgeTests.swift`:

```swift
import ControlProtocol
import MCP
import XCTest
@testable import MCPBridge

final class BridgeTests: XCTestCase {
    func params(_ name: String, _ arguments: [String: Value] = [:]) -> CallTool.Parameters {
        CallTool.Parameters(name: name, arguments: arguments)
    }

    func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    func testCatalogMatchesSpecPhase2() {
        XCTAssertEqual(ToolCatalog.specs.map(\.name),
                       ["list_vms", "start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key"])
        for spec in ToolCatalog.specs where spec.name != "list_vms" {
            XCTAssertTrue(spec.required.contains("vm"), spec.name)
            XCTAssertFalse(spec.description.isEmpty)
        }
    }

    func testScreenshotBecomesImagePlusText() async {
        let fake = FakeControl([.success(["image_png_base64": "iVBORw0KGgo=", "width": 1280, "height": 800, "scale": 1])])
        let result = await Bridge(client: fake, launcher: FakeLauncher()).handle(params("screenshot", ["vm": "u"]))
        XCTAssertEqual(result.isError, false)
        guard case .image(let data, let mime, _, _) = result.content.first else { return XCTFail("\(result.content)") }
        XCTAssertEqual(data, "iVBORw0KGgo=")
        XCTAssertEqual(mime, "image/png")
        XCTAssertTrue(text(result).contains("\"width\" : 1280"))
        XCTAssertFalse(text(result).contains("iVBOR"))
    }

    func testArgumentsAreForwardedUnchanged() async {
        let fake = FakeControl([.success(["ok": true])])
        _ = await Bridge(client: fake, launcher: FakeLauncher())
            .handle(params("click", ["vm": "u", "x": 10.5, "y": 3, "button": "right"]))
        let call = await fake.calls.first
        XCTAssertEqual(call?.method, "click")
        XCTAssertEqual(call?.params, ["vm": "u", "x": 10.5, "y": 3, "button": "right"])
    }

    func testControlErrorBecomesIsError() async {
        let fake = FakeControl([.failure(ControlError(code: .agentControlDisabled, message: "apagado"))])
        let result = await Bridge(client: fake, launcher: FakeLauncher()).handle(params("click", ["vm": "u", "x": 1, "y": 1]))
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(text(result), "agent_control_disabled: apagado")
    }

    /// Foco de revisión 3: app no corriendo → se lanza y se reintenta una vez.
    func testAppUnavailableLaunchesAndRetriesOnce() async {
        let fake = FakeControl([.failure(ControlError(code: .appUnavailable, message: "x")), .success(["vms": []])])
        let launcher = FakeLauncher()
        let result = await Bridge(client: fake, launcher: launcher).handle(params("list_vms"))
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(launcher.launches.value, 1)
        let count = await fake.calls.count
        XCTAssertEqual(count, 2)
    }

    func testLaunchFailureIsAppUnavailable() async {
        let fake = FakeControl([.failure(ControlError(code: .appUnavailable, message: "x"))])
        let result = await Bridge(client: fake, launcher: FakeLauncher(succeeds: false)).handle(params("list_vms"))
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).hasPrefix("app_unavailable"))
    }

    func testUnknownTool() async {
        let result = await Bridge(client: FakeControl([]), launcher: FakeLauncher()).handle(params("format_disk"))
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).hasPrefix("invalid_argument"))
    }

    func testTimeouts() async {
        let fake = FakeControl([.success(["state": "running"]), .success(["ok": true])])
        let bridge = Bridge(client: fake, launcher: FakeLauncher())
        _ = await bridge.handle(params("start_vm", ["vm": "u"]))
        _ = await bridge.handle(params("type_text", ["vm": "u", "text": .string(String(repeating: "a", count: 1000))]))
        let timeouts = await fake.calls.map(\.timeout)
        XCTAssertEqual(timeouts, [120, 80])
    }

    /// Protocolo de punta a punta: cliente MCP ↔ vmbox-mcp (Bridge) ↔ socket simulado.
    func testEndToEndOverMCPAndSocket() async throws {
        let path = "/tmp/vmbox-bridge-\(UUID().uuidString.prefix(8)).sock"
        let controlServer = ControlServer(path: path) { request in
            switch request.method {
            case "screenshot":
                .success(id: request.id, result: ["image_png_base64": "iVBORw0KGgo=", "width": 1280, "height": 800, "scale": 1])
            default:
                .failure(id: request.id, error: ControlError(code: .agentControlDisabled, message: "apagado"))
            }
        }
        try controlServer.start()
        defer { controlServer.stop() }

        let server = Server(name: "vmbox", version: "test", capabilities: .init(tools: .init(listChanged: false)))
        await Bridge(client: ControlClient(path: path), launcher: FakeLauncher(succeeds: false)).register(on: server)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "0")
        try await client.connect(transport: clientTransport)

        let (tools, _) = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ToolCatalog.specs.map(\.name))

        let (content, isError) = try await client.callTool(name: "screenshot", arguments: ["vm": "u"])
        XCTAssertEqual(isError, false)
        guard case .image = content.first else { return XCTFail("\(content)") }

        let (errorContent, errorFlag) = try await client.callTool(name: "click", arguments: ["vm": "u", "x": 1, "y": 1])
        XCTAssertEqual(errorFlag, true)
        guard case .text(let message, _, _) = errorContent.first else { return XCTFail("\(errorContent)") }
        XCTAssertTrue(message.hasPrefix("agent_control_disabled"))
        await server.stop()
    }
}
```

- [ ] **Paso 4: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter BridgeTests`
Expected: FAIL de compilación (`cannot find 'Bridge' in scope`)

- [ ] **Paso 5: implementación**

`Packages/VMCore/Sources/MCPBridge/ToolCatalog.swift`:

```swift
import ControlProtocol
import MCP

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let properties: [String: Value]
    public let required: [String]
    /// Timeout (s) para la llamada al socket según los argumentos.
    public let timeout: @Sendable ([String: JSONValue]) -> Double

    public var tool: Tool {
        Tool(name: name, description: description, inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ]))
    }
}

public enum ToolCatalog {
    static func string(_ description: String) -> Value { .object(["type": "string", "description": .string(description)]) }
    static func number(_ description: String) -> Value { .object(["type": "number", "description": .string(description)]) }
    static func integer(_ description: String) -> Value { .object(["type": "integer", "description": .string(description)]) }
    static func boolean(_ description: String) -> Value { .object(["type": "boolean", "description": .string(description)]) }
    static func oneOf(_ values: [String], _ description: String) -> Value {
        .object(["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)])
    }
    static func fixed(_ seconds: Double) -> @Sendable ([String: JSONValue]) -> Double { { _ in seconds } }

    static let vm = string("VM name (or UUID) as returned by list_vms")
    static let x = number("X in pixels of the latest screenshot (origin top-left)")
    static let y = number("Y in pixels of the latest screenshot (origin top-left)")

    public static let specs: [ToolSpec] = [
        ToolSpec(name: "list_vms", description: "List VMs with name, os, state and agentControlEnabled.",
                 properties: [:], required: [], timeout: fixed(10)),
        ToolSpec(name: "start_vm", description: "Start a VM (VMBox opens its window). Returns the new state.",
                 properties: ["vm": vm], required: ["vm"], timeout: fixed(120)),
        ToolSpec(name: "stop_vm", description: "Ask the guest to shut down; with force=true, power it off if it does not stop within 30 s.",
                 properties: ["vm": vm, "force": boolean("Force power off after the timeout")], required: ["vm"], timeout: fixed(75)),
        ToolSpec(name: "screenshot",
                 description: "Capture the VM screen as a PNG at most 1280 px wide. click/drag/scroll coordinates use this image's pixel space.",
                 properties: ["vm": vm], required: ["vm"], timeout: fixed(30)),
        ToolSpec(name: "click", description: "Click at (x, y) of the latest screenshot.",
                 properties: ["vm": vm, "x": x, "y": y, "button": oneOf(["left", "right"], "Mouse button (default left)"),
                              "count": integer("1 = click, 2 = double click (default 1)")],
                 required: ["vm", "x", "y"], timeout: fixed(30)),
        ToolSpec(name: "drag", description: "Press at (from_x, from_y), drag to (to_x, to_y) and release.",
                 properties: ["vm": vm, "from_x": x, "from_y": y, "to_x": x, "to_y": y],
                 required: ["vm", "from_x", "from_y", "to_x", "to_y"], timeout: fixed(30)),
        ToolSpec(name: "scroll", description: "Scroll at (x, y). dy > 0 scrolls down, dx > 0 scrolls right (pixels).",
                 properties: ["vm": vm, "x": x, "y": y, "dx": number("Horizontal pixels"), "dy": number("Vertical pixels")],
                 required: ["vm", "x", "y", "dx", "dy"], timeout: fixed(30)),
        ToolSpec(name: "type_text",
                 description: "Type text with a US keyboard layout. Supports printable ASCII, \\n and \\t; other characters are rejected.",
                 properties: ["vm": vm, "text": string("Text to type")], required: ["vm", "text"],
                 timeout: { args in 30 + Double(args["text"]?.stringValue?.count ?? 0) * 0.05 }),
        ToolSpec(name: "key", description: "Press a key combination, e.g. cmd+space, ctrl+c, ctrl+alt+t, return, shift+tab, super, f5.",
                 properties: ["vm": vm, "combo": string("Modifiers and key joined by +")], required: ["vm", "combo"], timeout: fixed(30)),
    ]

    public static var tools: [Tool] { specs.map(\.tool) }

    public static func spec(named name: String) -> ToolSpec? { specs.first { $0.name == name } }
}
```

`Packages/VMCore/Sources/MCPBridge/Bridge.swift`:

```swift
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
```

- [ ] **Paso 6: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter BridgeTests`
Expected: PASS (9 tests)

- [ ] **Paso 7: commit**

```bash
git add Packages/VMCore
git commit -m "feat(mcp): catálogo de herramientas y puente MCP→socket de control"
```

---

### Tarea 2.9: Lanzar VMBox si no corre

**Archivos:**
- Crear: `Packages/VMCore/Sources/MCPBridge/AppLauncher.swift`, `Packages/VMCore/Tests/MCPBridgeTests/AppLauncherTests.swift`

**Interfaces:**
- Consume: `AppLaunching`, `UnixSocket.connect`, `ControlError`.
- Produce: `AppLauncher(socketPath:appBundle:timeout:open:canConnect:)` conforme a `AppLaunching`; `AppLauncher.appBundle(forExecutable:) -> URL?`; `AppLauncher.runOpen(_:)`, `AppLauncher.probe(_:)`.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/MCPBridgeTests/AppLauncherTests.swift`:

```swift
import ControlProtocol
import Foundation
import XCTest
@testable import MCPBridge

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String]] = []
    private var probes = 0
    func add(_ args: [String]) { lock.withLock { items.append(args) } }
    var calls: [[String]] { lock.withLock { items } }
    func nextProbe() -> Int { lock.withLock { probes += 1; return probes } }
}

final class AppLauncherTests: XCTestCase {
    func testBundleFromEmbeddedExecutable() {
        XCTAssertEqual(AppLauncher.appBundle(forExecutable: URL(filePath: "/Applications/VMBox.app/Contents/MacOS/vmbox-mcp"))?.path,
                       "/Applications/VMBox.app")
        XCTAssertNil(AppLauncher.appBundle(forExecutable: URL(filePath: "/usr/local/bin/vmbox-mcp")))
    }

    func testOpensBundleAndWaitsForSocket() async throws {
        let recorder = Recorder()
        let launcher = AppLauncher(socketPath: "/tmp/x.sock", appBundle: URL(filePath: "/Applications/VMBox.app"),
                                   timeout: .seconds(5), open: { recorder.add($0) },
                                   canConnect: { _ in recorder.nextProbe() >= 3 })
        try await launcher.ensureRunning()
        XCTAssertEqual(recorder.calls, [["/Applications/VMBox.app"]])
    }

    func testFallsBackToOpenDashA() async throws {
        let recorder = Recorder()
        let launcher = AppLauncher(socketPath: "/tmp/x.sock", appBundle: nil, timeout: .seconds(1),
                                   open: { recorder.add($0) }, canConnect: { _ in true })
        try await launcher.ensureRunning()
        XCTAssertEqual(recorder.calls, [["-a", "VMBox"]])
    }

    func testTimesOutWithAppUnavailable() async {
        let launcher = AppLauncher(socketPath: "/tmp/x.sock", appBundle: nil, timeout: .milliseconds(300),
                                   open: { _ in }, canConnect: { _ in false })
        do {
            try await launcher.ensureRunning()
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .appUnavailable)
        } catch {
            XCTFail("\(error)")
        }
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter AppLauncherTests`
Expected: FAIL de compilación (`cannot find 'AppLauncher' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/MCPBridge/AppLauncher.swift`:

```swift
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
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore`
Expected: PASS (todos los tests del paquete)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(mcp): abrir VMBox y esperar su socket si no está corriendo"
```

---

### Tarea 2.10: Ejecutable `vmbox-mcp` embebido en `Contents/MacOS`

**Archivos:**
- Crear: `vmbox-mcp/main.swift`
- Modificar: `project.yml`

**Interfaces:**
- Consume: `Bridge`, `AppLauncher`, `ControlClient`, `ControlPaths`, `Server`, `StdioTransport`.
- Produce: `VMBox.app/Contents/MacOS/vmbox-mcp` (servidor MCP stdio).

- [ ] **Paso 1: punto de entrada**

`vmbox-mcp/main.swift`:

```swift
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
```

- [ ] **Paso 2: target y embebido en `project.yml`**

En `project.yml`, dentro de `targets:` añade el target nuevo:

```yaml
  vmbox-mcp:
    type: tool
    platform: macOS
    sources: [vmbox-mcp]
    settings:
      base:
        PRODUCT_NAME: vmbox-mcp
        SKIP_INSTALL: YES
    dependencies:
      - package: VMCore
        products: [MCPBridge, ControlProtocol]
```

y reemplaza las `dependencies` del target `VMBox` por:

```yaml
    dependencies:
      - package: VMCore
        products: [VMCore, ControlProtocol, AgentControl]
      - target: vmbox-mcp
        embed: true
        link: false
        copy:
          destination: executables
```

- [ ] **Paso 3: compilar y verificar el bundle**

Run: `scripts/build.sh && ls build/Build/Products/Debug/VMBox.app/Contents/MacOS/`
Expected: `BUILD SUCCEEDED` y el listado muestra `VMBox` y `vmbox-mcp`.

Run: `codesign --verify --deep --strict build/Build/Products/Debug/VMBox.app && echo firma-ok`
Expected: `firma-ok`

- [ ] **Paso 4: humo del protocolo MCP (sin la app)**

Con VMBox cerrado. El `sleep` mantiene stdin abierto: si stdin se cierra al instante, el servidor termina antes de responder (con Claude Code stdin queda abierto).

Run:

```bash
(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 2) | build/Build/Products/Debug/VMBox.app/Contents/MacOS/vmbox-mcp | grep -o '"name":"[a-z_]*"' | sort -u
```

Expected: `"name":"click"`, `"name":"drag"`, `"name":"key"`, `"name":"list_vms"`, `"name":"screenshot"`, `"name":"scroll"`, `"name":"start_vm"`, `"name":"stop_vm"`, `"name":"type_text"` y `"name":"vmbox"` (verificado al escribir el plan con un build de prueba; ahí, una llamada a `list_vms` sin la app devolvió `isError: true` con `app_unavailable` y el proceso siguió vivo).

- [ ] **Paso 5: commit**

```bash
git add vmbox-mcp project.yml
git commit -m "feat(mcp): ejecutable vmbox-mcp embebido en VMBox.app/Contents/MacOS"
```

---

### Tarea 2.11: App — captura, inyección, adaptador y servidor de control

**Archivos:**
- Crear: `VMBox/Control/ViewCapture.swift`, `VMBox/Control/ViewInputInjector.swift`, `VMBox/Control/ControlHost.swift`, `VMBox/Model/AgentVMAdapter.swift`
- Modificar: `VMBox/Model/AppModel.swift`, `VMBox/Views/VMWindowView.swift`

**Interfaces:**
- Consume: decisiones de `docs/spikes/2026-10-fase0-resultados.md`; `VMControlling`, `VMDirectory`, `ControlService`, `MCPLog`, `ControlServer`, `ControlPaths`, `InputAction`, `KeyStroke`, `KeyMap.modifierKeyCodes`.
- Produce: `ViewCapture.capture(_:) -> CGImage?`; `ViewInputInjector(view:).perform(_:) async`; `AgentVMAdapter(instance:model:)` (`VMControlling`); `ControlHost(model:)` con `start() throws`; en `AppModel`: `mcpLog`, `register(view:for:)`, `view(for:)`, `noteAgentActivity(_:)`, `isAgentActive(_:at:within:)`, `setAgentControl(_:_:)` y conformidad a `VMDirectory`.

- [ ] **Paso 1: captura (estrategia ganadora del spike)**

`VMBox/Control/ViewCapture.swift`:

```swift
import AppKit
import CoreImage
import IOSurface

@MainActor
enum ViewCapture {
    enum Strategy { case cacheDisplay, layerRender, layerIOSurface }

    /// Estrategia elegida en la Fase 0. Ajustar a la registrada en docs/spikes/2026-10-fase0-resultados.md.
    static let chosen: Strategy = .layerIOSurface

    static func capture(_ view: NSView) -> CGImage? {
        switch chosen {
        case .cacheDisplay: cacheDisplay(view)
        case .layerRender: layerRender(view)
        case .layerIOSurface: layerIOSurface(view)
        }
    }

    private static func cacheDisplay(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func layerRender(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    private static func layerIOSurface(_ view: NSView) -> CGImage? {
        guard let root = view.layer, let surface = findSurface(in: root) else { return nil }
        let image = CIImage(ioSurface: surface)
        return CIContext().createCGImage(image, from: image.extent)
    }

    private static func findSurface(in layer: CALayer) -> IOSurface? {
        if let surface = layer.contents as? IOSurface { return surface }
        for sublayer in layer.sublayers ?? [] {
            if let surface = findSurface(in: sublayer) { return surface }
        }
        return nil
    }
}
```

Fija `chosen` al valor de los resultados del spike y borra las funciones de las estrategias descartadas.

- [ ] **Paso 2: inyección (ruta ganadora del spike)**

`VMBox/Control/ViewInputInjector.swift`:

```swift
import AgentControl
import AppKit
import VMCore

@MainActor
struct ViewInputInjector {
    enum Route { case directToView, windowSendEvent, appPostEvent }

    /// Ruta elegida en la Fase 0. Ajustar a la registrada en docs/spikes/2026-10-fase0-resultados.md.
    static let route: Route = .windowSendEvent

    let view: NSView
    var stepDelay: Duration = .milliseconds(20)

    func perform(_ action: InputAction) async {
        switch action {
        case let .click(point, button, count): await click(at: point, button: button, count: count)
        case let .drag(from, to): await drag(from: from, to: to)
        case let .scroll(point, dx, dy): await scroll(at: point, dx: dx, dy: dy)
        case let .keys(strokes): for stroke in strokes { await press(stroke) }
        }
    }

    // MARK: Entrega

    private func deliver(_ event: NSEvent) {
        switch Self.route {
        case .directToView:
            switch event.type {
            case .keyDown: view.keyDown(with: event)
            case .keyUp: view.keyUp(with: event)
            case .flagsChanged: view.flagsChanged(with: event)
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .rightMouseDown: view.rightMouseDown(with: event)
            case .rightMouseUp: view.rightMouseUp(with: event)
            case .mouseMoved: view.mouseMoved(with: event)
            case .scrollWheel: view.scrollWheel(with: event)
            default: break
            }
        case .windowSendEvent: view.window?.sendEvent(event)
        case .appPostEvent: NSApp.postEvent(event, atStart: false)
        }
    }

    private func pause() async { try? await Task.sleep(for: stepDelay) }

    // MARK: Teclado

    private static let modifiers: [(KeyModifiers, NSEvent.ModifierFlags)] = [
        (.control, .control), (.option, .option), (.shift, .shift), (.command, .command),
    ]

    private func keyEvent(_ type: NSEvent.EventType, _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    func press(_ stroke: KeyStroke) async {
        let held = Self.modifiers.filter { stroke.modifiers.contains($0.0) }
        var flags: NSEvent.ModifierFlags = []
        for (modifier, flag) in held {
            flags.insert(flag)
            deliver(keyEvent(.flagsChanged, KeyMap.modifierKeyCodes[modifier]!, "", flags))
            await pause()
        }
        if let own = Self.modifiers.first(where: { KeyMap.modifierKeyCodes[$0.0] == stroke.keyCode }) {
            // Modificadora sola (p. ej. "super"): pulsar y soltar.
            deliver(keyEvent(.flagsChanged, stroke.keyCode, "", flags.union(own.1)))
            await pause()
            deliver(keyEvent(.flagsChanged, stroke.keyCode, "", flags))
            await pause()
        } else {
            deliver(keyEvent(.keyDown, stroke.keyCode, stroke.characters, flags))
            await pause()
            deliver(keyEvent(.keyUp, stroke.keyCode, stroke.characters, flags))
            await pause()
        }
        for (modifier, flag) in held.reversed() {
            flags.remove(flag)
            deliver(keyEvent(.flagsChanged, KeyMap.modifierKeyCodes[modifier]!, "", flags))
            await pause()
        }
    }

    // MARK: Mouse (puntos de la vista)

    private func mouseEvent(_ type: NSEvent.EventType, _ point: CGPoint, clickCount: Int = 1) -> NSEvent {
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: clickCount, pressure: isUp ? 0 : 1)!
    }

    func click(at point: CGPoint, button: MouseButton, count: Int) async {
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        deliver(mouseEvent(.mouseMoved, point))
        await pause()
        for n in 1...count {
            deliver(mouseEvent(down, point, clickCount: n))
            await pause()
            deliver(mouseEvent(up, point, clickCount: n))
            await pause()
        }
    }

    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 12) async {
        deliver(mouseEvent(.mouseMoved, start))
        await pause()
        deliver(mouseEvent(.leftMouseDown, start))
        await pause()
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            deliver(mouseEvent(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
            await pause()
        }
        deliver(mouseEvent(.leftMouseUp, end))
        await pause()
    }

    /// dy > 0 desplaza hacia abajo (contenido sube). Si el spike mostró lo contrario, invertir los signos.
    func scroll(at point: CGPoint, dx: Double, dy: Double) async {
        deliver(mouseEvent(.mouseMoved, point))
        await pause()
        guard let window = view.window,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        if let event = NSEvent(cgEvent: cgEvent) { deliver(event) }
        await pause()
    }
}
```

Fija `route` al valor del spike. Si el spike concluyó que las modificadoras **no** necesitan `flagsChanged`, se mantiene igual (los eventos extra son inocuos); si concluyó que sí, ya está cubierto.

- [ ] **Paso 3: adaptador `VMControlling`**

`VMBox/Model/AgentVMAdapter.swift`:

```swift
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
```

- [ ] **Paso 4: servidor de control en la app**

`VMBox/Control/ControlHost.swift`:

```swift
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
```

- [ ] **Paso 5: ampliar `AppModel`**

En `VMBox/Model/AppModel.swift`:

1. Añade los imports `import AgentControl` e `import Virtualization`.
2. Añade estas propiedades después de `var openVMWindow`:

```swift
    let mcpLog = MCPLog(fileURL: VMBoxPaths.mcpLog)
    private(set) var agentActivity: [UUID: Date] = [:]
    @ObservationIgnored private var views: [UUID: WeakView] = [:]
    @ObservationIgnored private var controlHost: ControlHost?
```

3. Al final de `init()` (después de `reload()`):

```swift
        let host = ControlHost(model: self)
        do {
            try host.start()
        } catch {
            alertMessage = "El control de agentes no está disponible: \(error.localizedDescription)"
        }
        controlHost = host
```

4. Añade estos métodos dentro de la clase:

```swift
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
```

5. Al final del archivo:

```swift
final class WeakView {
    weak var view: VZVirtualMachineView?
    init(_ view: VZVirtualMachineView) { self.view = view }
}

extension AppModel: VMDirectory {
    func allVMs() -> [any VMControlling] { vms.map { AgentVMAdapter(instance: $0, model: self) } }
}
```

- [ ] **Paso 6: registrar la vista al crearla**

En `VMBox/Views/VMWindowView.swift`, reemplaza `VMDisplayView(machine: vm.machine)` por:

```swift
                    VMDisplayView(machine: vm.machine) { model.register(view: $0, for: vm.id) }
```

- [ ] **Paso 7: compilar y probar contra una VM real**

Run: `scripts/build.sh && open build/Build/Products/Debug/VMBox.app`
Expected: `BUILD SUCCEEDED`; `ls -l ~/Library/Application\ Support/VMBox/control.sock` muestra `srw-------`.

Con la VM Ubuntu instalada (con inicio de sesión automático o tras iniciar sesión a mano) y sin activar aún el control de agente (la UI llega en 2.12), activarlo editando el config: `VMBOX_VM="$HOME/Library/Application Support/VMBox/VMs/Ubuntu.vmbox/config.json"; sed -i '' 's/"agentControlEnabled" : false/"agentControlEnabled" : true/' "$VMBOX_VM"` y reiniciar la app. Luego la prueba de humo de la Tarea 2.13 (paso 1) debe funcionar: captura, `ctrl+alt+t`, texto. Verificar también que `scroll` con `dy: 300` baja el contenido; si sube, invertir los signos en `ViewInputInjector.scroll`.

- [ ] **Paso 8: commit**

```bash
git add VMBox
git commit -m "feat(app): servidor de control, captura e inyección en la vista de la VM"
```

---

### Tarea 2.12: App — interruptor, banner, indicador y Ajustes

**Archivos:**
- Crear: `VMBox/Views/SettingsView.swift`
- Modificar: `VMBox/Views/VMToolbar.swift`, `VMBox/Views/VMWindowView.swift`, `VMBox/Views/LibraryView.swift`, `VMBox/VMBoxApp.swift`

**Interfaces:**
- Consume: `AppModel.setAgentControl`, `isAgentActive`, `mcpLog.recent`, `libraryPathKey`.
- Produce: UI de spec §4 para la Fase 2.

- [ ] **Paso 1: interruptor en la barra de la VM**

En `VMBox/Views/VMToolbar.swift`, antes de `Spacer()`, añade:

```swift
            Toggle("Permitir control de agente", isOn: Binding(
                get: { vm.config.agentControlEnabled },
                set: { model.setAgentControl(vm.id, $0) }
            ))
            .toggleStyle(.switch)
            .labelStyle(.titleAndIcon)
            .help("Permite que vmbox-mcp (p. ej. Claude Code) vea y controle esta VM")
```

- [ ] **Paso 2: banner "🤖 Agente controlando"**

En `VMBox/Views/VMWindowView.swift`, justo después de `Divider()`:

```swift
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if model.isAgentActive(vm.id, at: context.date) {
                        Text("🤖 Agente controlando")
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity)
                            .padding(4)
                            .background(.yellow.opacity(0.35))
                    }
                }
```

- [ ] **Paso 3: indicador en la biblioteca**

En `VMBox/Views/LibraryView.swift`, añade una columna después de "Disco":

```swift
            TableColumn("Agente") { vm in
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if model.isAgentActive(vm.id, at: context.date, within: 60) {
                        Text("🤖 conectado")
                    } else if vm.config.agentControlEnabled {
                        Text("permitido").foregroundStyle(.secondary)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
            }
```

- [ ] **Paso 4: ventana de Ajustes**

`VMBox/Views/SettingsView.swift`:

```swift
import AppKit
import SwiftUI
import VMCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.libraryPathKey) private var libraryPath = VMLibrary.defaultRoot.path
    @State private var choosingFolder = false

    private var mcpCommand: String {
        "claude mcp add vmbox -- \"\(Bundle.main.bundleURL.path)/Contents/MacOS/vmbox-mcp\""
    }

    var body: some View {
        Form {
            Section("Biblioteca") {
                HStack {
                    TextField("Ruta", text: $libraryPath)
                    Button("Elegir…") { choosingFolder = true }
                }
                Text("Se aplica al reiniciar VMBox.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                Text(mcpCommand).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("Copiar comando para Claude Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpCommand, forType: .string)
                }
            }
            Section("Log del MCP") {
                List(model.mcpLog.recent.reversed()) { entry in
                    HStack {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                        Text(entry.method).bold()
                        Text(entry.vm ?? "").foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.errorCode ?? "ok").foregroundStyle(entry.ok ? .green : .red)
                        Text("\(entry.durationMs) ms").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .frame(minHeight: 200)
                Button("Mostrar mcp.log en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([VMBoxPaths.mcpLog])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { libraryPath = url.path }
        }
    }
}
```

En `VMBox/VMBoxApp.swift`, añade al final de `body`:

```swift
        Settings {
            SettingsView()
                .environment(model)
        }
```

- [ ] **Paso 5: compilar y verificar**

Run: `scripts/build.sh && open build/Build/Products/Debug/VMBox.app`
Expected: el interruptor aparece apagado en VMs nuevas y su cambio persiste en `config.json`; VMBox ▸ Ajustes… (⌘,) muestra el comando con la ruta real de la app y el log.

- [ ] **Paso 6: commit**

```bash
git add VMBox
git commit -m "feat(app): interruptor de control de agente, banner, indicador y Ajustes"
```

---

### Tarea 2.13: Integración semiautomática y aceptación de la Fase 2

**Archivos:**
- Crear: `scripts/mcp_smoke.py`
- Modificar: `README.md`

**Interfaces:**
- Consume: `vmbox-mcp` instalado en el bundle.
- Produce: script reutilizado por las Fases 3 y 4 (pasos `snapshot:`, `restore:`, `run:` ya incluidos).

- [ ] **Paso 1: script de humo**

`scripts/mcp_smoke.py`:

```python
#!/usr/bin/env python3
"""Prueba de humo: habla MCP por stdio con vmbox-mcp y ejecuta una secuencia de herramientas.

Uso: scripts/mcp_smoke.py <ruta a vmbox-mcp> <vm> paso [paso...]
Pasos: list | start | stop | screenshot:<archivo.png> | key:<combo> | type:<texto, \\n = Enter>
       | click:<x>,<y> | sleep:<segundos> | snapshot:<nombre> | restore:<nombre> | run:<comando>
       | expect-error:<código> (el siguiente paso debe fallar con ese código)
"""
import base64
import json
import subprocess
import sys
import time


def main() -> None:
    exe, vm, steps = sys.argv[1], sys.argv[2], sys.argv[3:]
    proc = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    counter = [0]

    def rpc(method, params=None, notify=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            counter[0] += 1
            message["id"] = counter[0]
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()
        if notify:
            return None
        while True:
            line = proc.stdout.readline()
            if not line:
                raise SystemExit("vmbox-mcp terminó inesperadamente")
            response = json.loads(line)
            if response.get("id") == message["id"]:
                return response

    rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "smoke", "version": "0"}})
    rpc("notifications/initialized", notify=True)

    expected_error = [None]

    def tool(name, args):
        result = rpc("tools/call", {"name": name, "arguments": args})["result"]
        texts = " ".join(c["text"] for c in result["content"] if c["type"] == "text")
        images = [c["data"] for c in result["content"] if c["type"] == "image"]
        print(f"{name} {json.dumps(args)[:120]} -> isError={result.get('isError')} {texts[:300]}")
        if expected_error[0]:
            code, expected_error[0] = expected_error[0], None
            if not (result.get("isError") and texts.startswith(code)):
                raise SystemExit(f"se esperaba el error {code}")
            return []
        if result.get("isError"):
            raise SystemExit(1)
        return images

    for step in steps:
        kind, _, arg = step.partition(":")
        if kind == "list":
            tool("list_vms", {})
        elif kind == "start":
            tool("start_vm", {"vm": vm})
        elif kind == "stop":
            tool("stop_vm", {"vm": vm, "force": True})
        elif kind == "screenshot":
            image = tool("screenshot", {"vm": vm})
            if image:
                with open(arg, "wb") as f:
                    f.write(base64.b64decode(image[0]))
                print(f"  guardada {arg}")
        elif kind == "key":
            tool("key", {"vm": vm, "combo": arg})
        elif kind == "type":
            tool("type_text", {"vm": vm, "text": arg.replace("\\n", "\n")})
        elif kind == "click":
            x, y = arg.split(",")
            tool("click", {"vm": vm, "x": float(x), "y": float(y)})
        elif kind == "sleep":
            time.sleep(float(arg))
        elif kind == "snapshot":
            tool("snapshot_create", {"vm": vm, "name": arg})
        elif kind == "restore":
            tool("snapshot_restore", {"vm": vm, "name": arg, "confirm": True})
        elif kind == "run":
            tool("run_command", {"vm": vm, "command": arg})
        elif kind == "expect-error":
            expected_error[0] = arg
        else:
            raise SystemExit(f"paso desconocido: {step}")

    proc.stdin.close()
    proc.wait(timeout=10)


if __name__ == "__main__":
    main()
```

Run (VMBox cerrado, VM "Ubuntu" con control de agente permitido e inicio de sesión automático):

```bash
chmod +x scripts/mcp_smoke.py && scripts/mcp_smoke.py build/Build/Products/Debug/VMBox.app/Contents/MacOS/vmbox-mcp Ubuntu list start sleep:60 screenshot:/tmp/vmbox-1.png key:ctrl+alt+t sleep:3 type:'echo vmbox-ok\n' sleep:2 screenshot:/tmp/vmbox-2.png
```

Expected: VMBox se abre solo (≤15 s), la VM arranca y abre su ventana con el banner "🤖 Agente controlando" durante la entrada; `/tmp/vmbox-2.png` (≤1280 px de ancho) muestra una terminal con `vmbox-ok`. Ajustes ▸ Log del MCP lista cada llamada y `~/Library/Application Support/VMBox/mcp.log` tiene una línea JSON por llamada.

- [ ] **Paso 2: casos de error**

Run: apagar el interruptor de la VM y ejecutar

```bash
scripts/mcp_smoke.py build/Build/Products/Debug/VMBox.app/Contents/MacOS/vmbox-mcp Ubuntu list expect-error:agent_control_disabled screenshot:/tmp/x.png
```

Expected: `list_vms` funciona (muestra `agentControlEnabled: false`) y `screenshot` devuelve `agent_control_disabled`. Con el interruptor encendido: `expect-error:invalid_argument type:'ñandú'` pasa y no aparece nada escrito en la VM.

- [ ] **Paso 3: aceptación con Claude Code**

Run: copiar el comando desde Ajustes y ejecutarlo en una terminal; luego, en Claude Code: «En la VM Ubuntu de VMBox, abre una terminal y ejecuta `uname -a`; dime el resultado». Repetir con la VM macOS: «abre Safari en la VM de macOS y busca "Virtualization framework"».
Expected: el agente lo logra usando `screenshot`, `click`, `key` y `type_text`; el banner aparece en la ventana de la VM; la Mac anfitriona no recibe teclas ni clics (el cursor del usuario no se mueve).

- [ ] **Paso 4: README**

Añade a `README.md`:

````markdown
## Control por agentes (MCP)
1. En la ventana de la VM, activa **Permitir control de agente**.
2. VMBox ▸ Ajustes ▸ **Copiar comando para Claude Code** y ejecútalo, o:
   ```bash
   claude mcp add vmbox -- "/Applications/VMBox.app/Contents/MacOS/vmbox-mcp"
   ```
3. Herramientas: `list_vms`, `start_vm`, `stop_vm`, `screenshot`, `click`, `drag`, `scroll`, `type_text`, `key`.
   `type_text` usa distribución de teclado US: configura el invitado con teclado US.
4. Prueba rápida sin Claude: `scripts/mcp_smoke.py <ruta a vmbox-mcp> <vm> list start screenshot:/tmp/a.png`.
````

- [ ] **Paso 5: commit**

```bash
git add scripts/mcp_smoke.py README.md
git commit -m "test: prueba de humo MCP y documentación del control por agentes"
```
