# VMBox — Fase 3: snapshots y carpetas compartidas

> **Para agentes:** SUB-SKILL REQUERIDO: usa superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar este plan tarea por tarea. Los pasos usan casillas (`- [ ]`). Lee primero el índice [2026-10-08-vmbox-mvp-00-indice.md](2026-10-08-vmbox-mvp-00-indice.md). **Requisito:** Fase 2 terminada.

**Objetivo:** crear, listar, restaurar y eliminar snapshots (disco con `clonefile` y, con la VM encendida, también el estado de memoria) desde la UI y desde el MCP, y compartir carpetas del host con la VM por VirtioFS.

**Arquitectura:** `SnapshotStore` (VMCore) gestiona `snapshots/<nombre>/` dentro del paquete: clona `disk.img`, `nvram.bin` y `aux.img` con `clonefile(2)` y guarda `info.json` (+ `state.vzvmsave` si incluye memoria). `VMInstance` orquesta pausa → guardar estado → clonar → reanudar, y la restauración (VM detenida → reemplazo atómico de archivos → el siguiente `start()` restaura memoria si la hay). Las carpetas compartidas son un único `VZVirtioFileSystemDeviceConfiguration` con `VZMultipleDirectoryShare`.

**Stack:** Swift 6.3, APFS `clonefile(2)`, Virtualization.framework (`saveMachineStateTo`/`restoreMachineStateFrom`, VirtioFS), XCTest, SwiftUI.

**Spec:** [docs/specs/2026-10-08-vmbox-design.md](../specs/2026-10-08-vmbox-design.md) §3.1, §3.2 (VirtioFS), §3.4, §4, §5.2 (`snapshot_*`), §5.4, §6.

## Estructura de archivos de esta fase

```
Packages/VMCore/Sources/VMCore/Snapshots/SnapshotStore.swift
Packages/VMCore/Sources/VMCore/Config/SharedFolderNaming.swift
Packages/VMCore/Sources/VMCore/Runtime/VMInstance.swift          (modificado: snapshots, restauración en start)
Packages/VMCore/Sources/VMCore/Runtime/VMConfigurationBuilder.swift (modificado: VirtioFS)
Packages/VMCore/Sources/AgentControl/VMControlling.swift, ControlService.swift (modificados)
Packages/VMCore/Sources/MCPBridge/ToolCatalog.swift              (modificado)
Packages/VMCore/Tests/VMCoreTests/SnapshotStoreTests.swift, SharedFoldersTests.swift
Packages/VMCore/Tests/AgentControlTests/ (Fakes y ControlServiceTests modificados, SnapshotToolsTests nuevo)
Packages/VMCore/Tests/MCPBridgeTests/BridgeTests.swift           (modificado)
VMBox/Views/SnapshotsSheet.swift (nuevo), VMSettingsSheet.swift (reemplazo), VMToolbar.swift y LibraryView.swift (modificados)
VMBox/Model/AgentVMAdapter.swift (modificado)
```

---

### Tarea 3.1: `SnapshotStore` (clonefile, info, restauración atómica)

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Snapshots/SnapshotStore.swift`, `Packages/VMCore/Tests/VMCoreTests/SnapshotStoreTests.swift`

**Interfaces:**
- Consume: `VMBundle`, `VMName.validate`.
- Produce: `SnapshotInfo { name, createdAt: Date, includesMemory: Bool; id }`, `SnapshotError` (`invalidName`, `alreadyExists`, `notFound`, `cloneFailed(String, Int32)`), `SnapshotStore(bundle:)` con `directory(for:)`, `memoryStateURL(for:)`, `list() throws -> [SnapshotInfo]`, `info(_:) throws -> SnapshotInfo`, `create(name:includesMemory:date:saveState:) async throws -> SnapshotInfo`, `restoreFiles(_:) throws`, `delete(_:) throws`, `static clonedFiles = ["disk.img", "nvram.bin", "aux.img"]`.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/SnapshotStoreTests.swift`:

```swift
import XCTest
@testable import VMCore

final class SnapshotStoreTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var bundle: VMBundle!
    var store: SnapshotStore!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.diskBytes = 1 << 20
        bundle = try VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory)).create(config)
        try Data("disco-v1".utf8).write(to: bundle.diskURL)
        try Data("nvram-v1".utf8).write(to: bundle.nvramURL)
        store = SnapshotStore(bundle: bundle)
    }

    func testCreateClonesFilesAndWritesInfo() async throws {
        let info = try await store.create(name: "limpio", includesMemory: false)
        XCTAssertEqual(info.name, "limpio")
        XCTAssertFalse(info.includesMemory)
        let dir = store.directory(for: "limpio")
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "disk.img")), Data("disco-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "nvram.bin")), Data("nvram-v1".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "aux.img").path), "solo clona lo que existe")
        XCTAssertEqual(try store.list(), [info])
    }

    func testSnapshotIsIndependentOfLaterWrites() async throws {
        _ = try await store.create(name: "a", includesMemory: false)
        try Data("disco-v2".utf8).write(to: bundle.diskURL)
        XCTAssertEqual(try Data(contentsOf: store.directory(for: "a").appending(path: "disk.img")), Data("disco-v1".utf8))
    }

    func testRestoreReplacesFiles() async throws {
        _ = try await store.create(name: "a", includesMemory: false)
        try Data("disco-v2".utf8).write(to: bundle.diskURL)
        try Data("nvram-v2".utf8).write(to: bundle.nvramURL)
        try store.restoreFiles("a")
        XCTAssertEqual(try Data(contentsOf: bundle.diskURL), Data("disco-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: bundle.nvramURL), Data("nvram-v1".utf8))
        XCTAssertEqual(try Data(contentsOf: store.directory(for: "a").appending(path: "disk.img")), Data("disco-v1".utf8),
                       "restaurar no consume el snapshot")
    }

    func testMemoryStateIsSavedInsideSnapshot() async throws {
        let info = try await store.create(name: "vivo", includesMemory: true) { url in
            try Data("memoria".utf8).write(to: url)
        }
        XCTAssertTrue(info.includesMemory)
        XCTAssertEqual(try Data(contentsOf: store.memoryStateURL(for: "vivo")), Data("memoria".utf8))
    }

    func testFailedSaveLeavesNoSnapshot() async throws {
        struct Boom: Error {}
        do {
            _ = try await store.create(name: "roto", includesMemory: true) { _ in throw Boom() }
            XCTFail("debió lanzar")
        } catch is Boom {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: "roto").path))
        XCTAssertEqual(try store.list(), [])
    }

    func testNameRules() async throws {
        _ = try await store.create(name: "a", includesMemory: false)
        do {
            _ = try await store.create(name: "a", includesMemory: false)
            XCTFail("debió lanzar")
        } catch let error as SnapshotError {
            XCTAssertEqual(error, .alreadyExists("a"))
        }
        do {
            _ = try await store.create(name: "../fuera", includesMemory: false)
            XCTFail("debió lanzar")
        } catch let error as SnapshotError {
            XCTAssertEqual(error, .invalidName("../fuera"))
        }
        XCTAssertThrowsError(try store.restoreFiles("no-existe")) { XCTAssertEqual($0 as? SnapshotError, .notFound("no-existe")) }
    }

    func testListIsSortedByDateAndDeleteRemoves() async throws {
        _ = try await store.create(name: "nuevo", includesMemory: false, date: Date(timeIntervalSince1970: 2000))
        _ = try await store.create(name: "viejo", includesMemory: false, date: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(try store.list().map(\.name), ["viejo", "nuevo"])
        try store.delete("viejo")
        XCTAssertEqual(try store.list().map(\.name), ["nuevo"])
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter SnapshotStoreTests`
Expected: FAIL de compilación (`cannot find 'SnapshotStore' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/VMCore/Snapshots/SnapshotStore.swift`:

```swift
import Darwin
import Foundation

public struct SnapshotInfo: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var createdAt: Date
    public var includesMemory: Bool
    public var id: String { name }

    public init(name: String, createdAt: Date, includesMemory: Bool) {
        self.name = name
        self.createdAt = createdAt
        self.includesMemory = includesMemory
    }
}

public enum SnapshotError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case cloneFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "Nombre de snapshot inválido: «\(name)»"
        case .alreadyExists(let name): "Ya existe un snapshot «\(name)»"
        case .notFound(let name): "No existe el snapshot «\(name)»"
        case let .cloneFailed(file, code): "No se pudo clonar \(file): \(String(cString: strerror(code)))"
        }
    }
}

/// Snapshots en `<vm>.vmbox/snapshots/<nombre>/`: clones APFS de los archivos del disco y la NVRAM,
/// `info.json` y, si la VM estaba encendida, `state.vzvmsave`.
public struct SnapshotStore: Sendable {
    public static let clonedFiles = ["disk.img", "nvram.bin", "aux.img"]
    static let infoFile = "info.json"
    static let stateFile = "state.vzvmsave"

    public let bundle: VMBundle

    public init(bundle: VMBundle) { self.bundle = bundle }

    public func directory(for name: String) -> URL {
        bundle.snapshotsURL.appending(path: name, directoryHint: .isDirectory)
    }

    public func memoryStateURL(for name: String) -> URL {
        directory(for: name).appending(path: Self.stateFile)
    }

    public func list() throws -> [SnapshotInfo] {
        guard FileManager.default.fileExists(atPath: bundle.snapshotsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: bundle.snapshotsURL, includingPropertiesForKeys: nil)
            .compactMap { try? Self.decoder.decode(SnapshotInfo.self, from: Data(contentsOf: $0.appending(path: Self.infoFile))) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func info(_ name: String) throws -> SnapshotInfo {
        let url = directory(for: name).appending(path: Self.infoFile)
        guard let data = try? Data(contentsOf: url) else { throw SnapshotError.notFound(name) }
        return try Self.decoder.decode(SnapshotInfo.self, from: data)
    }

    /// Crea el snapshot. Si `includesMemory`, `saveState` debe escribir el estado en la URL recibida
    /// (con la VM pausada). Ante cualquier error, el directorio del snapshot se borra.
    public func create(name rawName: String, includesMemory: Bool, date: Date = .now,
                       saveState: @MainActor (URL) async throws -> Void = { _ in }) async throws -> SnapshotInfo {
        guard let name = try? VMName.validate(rawName) else { throw SnapshotError.invalidName(rawName) }
        let dir = directory(for: name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { throw SnapshotError.alreadyExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if includesMemory { try await saveState(dir.appending(path: Self.stateFile)) }
            for file in Self.clonedFiles where fm.fileExists(atPath: bundle.url.appending(path: file).path) {
                try Self.clone(bundle.url.appending(path: file), to: dir.appending(path: file))
            }
            // info.json guarda la fecha en ISO 8601 (segundos): truncar para que create y list coincidan.
            let created = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
            let info = SnapshotInfo(name: name, createdAt: created, includesMemory: includesMemory)
            try Self.encoder.encode(info).write(to: dir.appending(path: Self.infoFile))
            return info
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// Reemplaza los archivos de la VM por los del snapshot (la VM debe estar detenida).
    /// Cada archivo se clona a un temporal y se renombra encima del original (atómico).
    public func restoreFiles(_ name: String) throws {
        _ = try info(name)
        let dir = directory(for: name)
        for file in Self.clonedFiles where FileManager.default.fileExists(atPath: dir.appending(path: file).path) {
            let target = bundle.url.appending(path: file)
            let temporary = bundle.url.appending(path: file + ".restoring")
            try? FileManager.default.removeItem(at: temporary)
            try Self.clone(dir.appending(path: file), to: temporary)
            guard rename(temporary.path, target.path) == 0 else { throw SnapshotError.cloneFailed(file, errno) }
        }
    }

    public func delete(_ name: String) throws {
        _ = try info(name)
        try FileManager.default.removeItem(at: directory(for: name))
    }

    static func clone(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in clonefile(src!, dst!, 0) }
        }
        guard result == 0 else { throw SnapshotError.cloneFailed(source.lastPathComponent, errno) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter SnapshotStoreTests`
Expected: PASS (7 tests)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): snapshots con clonefile y restauración atómica"
```

---

### Tarea 3.2: Snapshots en `VMInstance` (estado de memoria y restauración al iniciar)

**Archivos:**
- Modificar: `Packages/VMCore/Sources/VMCore/Runtime/VMInstance.swift`

**Interfaces:**
- Consume: `SnapshotStore`, `DiskSpace`, `VMConfigurationBuilder.build`.
- Produce: en `VMInstance`: `snapshots: SnapshotStore`, `pendingRestoreState: URL?`, `createSnapshot(named:) async throws -> SnapshotInfo`, `restoreSnapshot(named:) async throws`; `VMInstanceError.invalidStateForSnapshot(VMState)`. `start()` restaura memoria si hay un estado pendiente (y arranca en frío si el estado no es compatible).

Sin tests unitarios nuevos (requiere una VM real): la lógica de archivos ya está cubierta por `SnapshotStoreTests`; la verificación es manual en la Tarea 3.6.

- [ ] **Paso 1: nuevo caso de error**

En `VMInstanceError` añade el caso y su descripción:

```swift
    case invalidStateForSnapshot(VMState)
```

```swift
        case .invalidStateForSnapshot(let state): "No se puede crear un snapshot con la VM «\(state.displayName)»."
```

- [ ] **Paso 2: propiedades**

En `VMInstance`, después de `private var stateMachine = VMStateMachine()`:

```swift
    /// Estado de memoria a restaurar en el próximo `start()` (lo fija `restoreSnapshot`).
    public private(set) var pendingRestoreState: URL?
    /// Si la configuración actual admite guardar/restaurar memoria (se calcula al iniciar).
    private var saveRestoreSupported = false

    public var snapshots: SnapshotStore { SnapshotStore(bundle: bundle) }
```

- [ ] **Paso 3: `start()` con restauración de memoria**

Reemplaza `start()` completo por:

```swift
    public func start() async throws {
        try stateMachine.apply(.startRequested)
        do {
            let configuration = try VMConfigurationBuilder.build(config: config, bundle: bundle)
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
                    let fresh = VZVirtualMachine(configuration: try VMConfigurationBuilder.build(config: config, bundle: bundle))
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
```

- [ ] **Paso 4: crear y restaurar snapshots**

Añade a `VMInstance`:

```swift
    /// Detenida: clona el disco. Encendida: pausa, guarda memoria (si se admite), clona y reanuda.
    public func createSnapshot(named name: String) async throws -> SnapshotInfo {
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
        let info = try snapshots.info(name)
        if state == .running || state == .paused {
            try await stop(force: true, timeout: .seconds(10))
        }
        try snapshots.restoreFiles(name)
        pendingRestoreState = info.includesMemory ? snapshots.memoryStateURL(for: name) : nil
    }
```

- [ ] **Paso 5: compilar y correr los tests**

Run: `swift build --package-path Packages/VMCore && swift test --package-path Packages/VMCore`
Expected: `Build complete!` y todos los tests PASS.

- [ ] **Paso 6: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): snapshots con estado de memoria y restauración al iniciar"
```

---

### Tarea 3.3: Herramientas `snapshot_create`, `snapshot_list`, `snapshot_restore`

**Archivos:**
- Modificar: `Packages/VMCore/Sources/AgentControl/VMControlling.swift`, `Packages/VMCore/Sources/AgentControl/ControlService.swift`, `Packages/VMCore/Sources/MCPBridge/ToolCatalog.swift`, `Packages/VMCore/Tests/AgentControlTests/Fakes.swift`, `Packages/VMCore/Tests/AgentControlTests/ControlServiceTests.swift`, `Packages/VMCore/Tests/MCPBridgeTests/BridgeTests.swift`, `VMBox/Model/AgentVMAdapter.swift`
- Crear: `Packages/VMCore/Tests/AgentControlTests/SnapshotToolsTests.swift`

**Interfaces:**
- Consume: `SnapshotInfo`, `SnapshotError`, `DiskSpaceError`, `VMInstance.createSnapshot/restoreSnapshot/snapshots`.
- Produce: requisitos nuevos en `VMControlling`: `createSnapshot(name:) async throws -> SnapshotInfo`, `listSnapshots() throws -> [SnapshotInfo]`, `restoreSnapshot(name:) async throws`. Resultados: `snapshot_create` → `{name, created_at, includes_memory}`; `snapshot_list` → `{"snapshots": [...]}`; `snapshot_restore` → `{"restored", "state"}`.

- [ ] **Paso 1: ampliar el fake**

En `Packages/VMCore/Tests/AgentControlTests/Fakes.swift`, añade a `FakeVM`:

```swift
    var snapshots: [SnapshotInfo] = []
    var restored: [String] = []

    func createSnapshot(name: String) async throws -> SnapshotInfo {
        let info = SnapshotInfo(name: name, createdAt: Date(timeIntervalSince1970: 0), includesMemory: state == .running)
        snapshots.append(info)
        return info
    }

    func listSnapshots() throws -> [SnapshotInfo] { snapshots }

    func restoreSnapshot(name: String) async throws {
        guard snapshots.contains(where: { $0.name == name }) else { throw SnapshotError.notFound(name) }
        restored.append(name)
        state = .stopped
    }
```

- [ ] **Paso 2: tests que fallan**

`Packages/VMCore/Tests/AgentControlTests/SnapshotToolsTests.swift`:

```swift
import AgentControl
import ControlProtocol
import XCTest
import VMCore

@MainActor
final class SnapshotToolsTests: XCTestCase {
    var vm: FakeVM!
    var service: ControlService!

    override func setUp() async throws {
        vm = FakeVM(name: "Ubuntu")
        service = ControlService(directory: FakeDirectory([vm, FakeVM(name: "Privada", agentControlEnabled: false)]))
    }

    func call(_ method: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await service.handle(ControlRequest(id: 1, method: method, params: params))
    }

    func testCreateAndList() async throws {
        let created = try await call("snapshot_create", ["vm": "Ubuntu", "name": "limpio"]).get()
        XCTAssertEqual(created, ["name": "limpio", "created_at": "1970-01-01T00:00:00Z", "includes_memory": true])
        let listed = try await call("snapshot_list", ["vm": "Ubuntu"]).get()
        XCTAssertEqual(listed, ["snapshots": [["name": "limpio", "created_at": "1970-01-01T00:00:00Z", "includes_memory": true]]])
    }

    func testCreateWorksWithStoppedVM() async throws {
        vm.state = .stopped
        let created = try await call("snapshot_create", ["vm": "Ubuntu", "name": "frio"]).get()
        XCTAssertEqual(created["includes_memory"], false)
    }

    func testRestoreRequiresConfirmTrue() async throws {
        _ = try await call("snapshot_create", ["vm": "Ubuntu", "name": "a"]).get()
        let withoutConfirm = await call("snapshot_restore", ["vm": "Ubuntu", "name": "a"])
        let confirmFalse = await call("snapshot_restore", ["vm": "Ubuntu", "name": "a", "confirm": false])
        let confirmString = await call("snapshot_restore", ["vm": "Ubuntu", "name": "a", "confirm": "true"])
        XCTAssertEqual(withoutConfirm.error?.data, .invalidArgument)
        XCTAssertEqual(confirmFalse.error?.data, .invalidArgument)
        XCTAssertEqual(confirmString.error?.data, .invalidArgument)
        XCTAssertEqual(vm.restored, [])

        let restored = try await call("snapshot_restore", ["vm": "Ubuntu", "name": "a", "confirm": true]).get()
        XCTAssertEqual(restored, ["restored": "a", "state": "stopped"])
        XCTAssertEqual(vm.restored, ["a"])
    }

    func testUnknownSnapshotIsInvalidArgument() async {
        let response = await call("snapshot_restore", ["vm": "Ubuntu", "name": "nada", "confirm": true])
        XCTAssertEqual(response.error?.data, .invalidArgument)
        XCTAssertTrue(response.error?.message.contains("nada") ?? false)
    }

    func testDisabledVMIsRejected() async {
        for method in ["snapshot_create", "snapshot_list", "snapshot_restore"] {
            let response = await call(method, ["vm": "Privada", "name": "x", "confirm": true])
            XCTAssertEqual(response.error?.data, .agentControlDisabled, method)
        }
    }
}
```

Run: `swift test --package-path Packages/VMCore --filter SnapshotToolsTests`
Expected: FAIL — compila (los métodos extra de `FakeVM` aún no son requisitos del protocolo), pero `snapshot_*` responde `invalid_argument: Método desconocido`.

- [ ] **Paso 3: requisitos del protocolo**

En `Packages/VMCore/Sources/AgentControl/VMControlling.swift`, dentro de `protocol VMControlling`, añade:

```swift
    func createSnapshot(name: String) async throws -> SnapshotInfo
    func listSnapshots() throws -> [SnapshotInfo]
    /// Detiene la VM y restaura el snapshot.
    func restoreSnapshot(name: String) async throws
```

- [ ] **Paso 4: métodos en `ControlService`**

En `Packages/VMCore/Sources/AgentControl/ControlService.swift`:

1. Amplía `vmMethods`:

```swift
    static let vmMethods: Set<String> = ["start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key",
                                         "snapshot_create", "snapshot_list", "snapshot_restore"]
```

2. Añade los structs de parámetros junto a los demás:

```swift
    struct SnapshotParams: Decodable { var vm: String; var name: String }
    struct RestoreParams: Decodable { var vm: String; var name: String; var confirm: Bool? }
```

3. Añade estos casos al `switch` de `dispatch`, antes de `default:`:

```swift
        case "snapshot_create":
            let p = try params.decode(as: SnapshotParams.self)
            return Self.snapshotJSON(try await vm.createSnapshot(name: p.name))

        case "snapshot_list":
            return ["snapshots": .array(try vm.listSnapshots().map(Self.snapshotJSON))]

        case "snapshot_restore":
            let p = try params.decode(as: RestoreParams.self)
            guard p.confirm == true else {
                throw ControlError(code: .invalidArgument,
                                   message: "snapshot_restore exige confirm: true (detiene la VM y descarta su estado actual)")
            }
            try await vm.restoreSnapshot(name: p.name)
            return ["restored": .string(p.name), "state": .string(vm.state.rawValue)]
```

4. Añade el ayudante:

```swift
    static func snapshotJSON(_ info: SnapshotInfo) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        return ["name": .string(info.name), "created_at": .string(formatter.string(from: info.createdAt)),
                "includes_memory": .bool(info.includesMemory)]
    }
```

5. En `controlError(from:)`, antes de `default:`, añade:

```swift
        case let error as SnapshotError: ControlError(code: .invalidArgument, message: error.localizedDescription)
        case let error as DiskSpaceError: ControlError(code: .internalError, message: error.localizedDescription)
```

6. En `ControlServiceTests.testDisabledVMIsRejectedForEveryToolButList`, la lista de métodos no cambia (sigue siendo válida).

- [ ] **Paso 5: herramientas MCP**

En `Packages/VMCore/Sources/MCPBridge/ToolCatalog.swift`, añade al final de `specs`:

```swift
        ToolSpec(name: "snapshot_create",
                 description: "Snapshot the VM disk (and memory if it is running). Works with the VM stopped or running.",
                 properties: ["vm": vm, "name": string("Snapshot name")], required: ["vm", "name"], timeout: fixed(300)),
        ToolSpec(name: "snapshot_list", description: "List snapshots with creation date and whether they include memory state.",
                 properties: ["vm": vm], required: ["vm"], timeout: fixed(30)),
        ToolSpec(name: "snapshot_restore",
                 description: "Stop the VM and restore a snapshot, discarding current state. Requires confirm: true. Then call start_vm.",
                 properties: ["vm": vm, "name": string("Snapshot name"), "confirm": boolean("Must be true")],
                 required: ["vm", "name", "confirm"], timeout: fixed(120)),
```

En `Packages/VMCore/Tests/MCPBridgeTests/BridgeTests.swift`, reemplaza `testCatalogMatchesSpecPhase2` por:

```swift
    func testCatalogMatchesSpec() {
        XCTAssertEqual(ToolCatalog.specs.map(\.name),
                       ["list_vms", "start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key",
                        "snapshot_create", "snapshot_list", "snapshot_restore"])
        for spec in ToolCatalog.specs where spec.name != "list_vms" {
            XCTAssertTrue(spec.required.contains("vm"), spec.name)
            XCTAssertFalse(spec.description.isEmpty)
        }
        XCTAssertTrue(ToolCatalog.spec(named: "snapshot_restore")!.required.contains("confirm"))
    }
```

- [ ] **Paso 6: verificar que pasa**

Run: `swift test --package-path Packages/VMCore`
Expected: PASS (todos)

- [ ] **Paso 7: adaptador de la app**

En `VMBox/Model/AgentVMAdapter.swift`, añade:

```swift
    func createSnapshot(name: String) async throws -> SnapshotInfo {
        try await instance.createSnapshot(named: name)
    }

    func listSnapshots() throws -> [SnapshotInfo] {
        try instance.snapshots.list()
    }

    func restoreSnapshot(name: String) async throws {
        try await instance.restoreSnapshot(named: name)
    }
```

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`

- [ ] **Paso 8: commit**

```bash
git add Packages/VMCore VMBox
git commit -m "feat(agent): herramientas MCP de snapshots con confirmación de restauración"
```

---

### Tarea 3.4: UI de snapshots

**Archivos:**
- Crear: `VMBox/Views/SnapshotsSheet.swift`
- Modificar: `VMBox/Views/VMToolbar.swift`, `VMBox/Views/LibraryView.swift`

**Interfaces:**
- Consume: `VMInstance.snapshots`, `createSnapshot(named:)`, `restoreSnapshot(named:)`, `AppModel.perform`.
- Produce: hoja de snapshots accesible desde 📸 en la ventana de la VM y desde "Snapshots" en la biblioteca.

- [ ] **Paso 1: hoja de snapshots**

`VMBox/Views/SnapshotsSheet.swift`:

```swift
import SwiftUI
import VMCore

struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vmID: UUID
    @State private var snapshots: [SnapshotInfo] = []
    @State private var newName = ""
    @State private var busy = false
    @State private var restoreTarget: SnapshotInfo?
    @State private var deleteTarget: SnapshotInfo?

    var body: some View {
        if let vm = model.instance(for: vmID) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Snapshots de «\(vm.config.name)»").font(.headline)
                List(snapshots) { snapshot in
                    HStack {
                        Image(systemName: snapshot.includesMemory ? "memorychip" : "internaldrive")
                            .help(snapshot.includesMemory ? "Incluye memoria" : "Solo disco")
                        Text(snapshot.name).bold()
                        Text(snapshot.createdAt, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restaurar") { restoreTarget = snapshot }
                        Button("Eliminar", role: .destructive) { deleteTarget = snapshot }
                    }
                }
                .frame(minHeight: 200)
                HStack {
                    TextField("Nombre del nuevo snapshot", text: $newName)
                    Button("Crear") { create(vm) }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                if busy { ProgressView().controlSize(.small) }
                HStack {
                    Spacer()
                    Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 560)
            .onAppear { reload(vm) }
            .confirmationDialog("¿Restaurar «\(restoreTarget?.name ?? "")»?", isPresented: Binding(
                get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
                Button("Detener la VM y restaurar", role: .destructive) {
                    guard let target = restoreTarget else { return }
                    run(vm) { try await vm.restoreSnapshot(named: target.name) }
                }
            } message: {
                Text("Se descarta el estado actual de la VM.")
            }
            .confirmationDialog("¿Eliminar «\(deleteTarget?.name ?? "")»?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button("Eliminar", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    run(vm) { try vm.snapshots.delete(target.name) }
                }
            }
        }
    }

    private func reload(_ vm: VMInstance) {
        snapshots = (try? vm.snapshots.list()) ?? []
    }

    private func create(_ vm: VMInstance) {
        let name = newName
        run(vm) {
            _ = try await vm.createSnapshot(named: name)
            newName = ""
        }
    }

    private func run(_ vm: VMInstance, _ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            await model.perform(action)
            busy = false
            reload(vm)
        }
    }
}
```

- [ ] **Paso 2: botón 📸 en la ventana de la VM**

En `VMBox/Views/VMToolbar.swift`:
1. Añade la propiedad `@State private var showingSnapshots = false`.
2. Después del `Menu` de detener, añade:

```swift
            Button("Snapshots", systemImage: "camera") { showingSnapshots = true }
```

3. Al final del `HStack` (después de `.padding(.vertical, 6)`), añade:

```swift
        .sheet(isPresented: $showingSnapshots) { SnapshotsSheet(vmID: vm.id) }
```

- [ ] **Paso 3: botón "Snapshots" en la biblioteca**

En `VMBox/Views/LibraryView.swift`:
1. Añade `@State private var snapshotsTarget: VMRef?`.
2. En la `toolbar`, antes de "Configuración":

```swift
            Button("Snapshots", systemImage: "camera") {
                if let id = selection { snapshotsTarget = VMRef(id: id) }
            }
            .disabled(selection == nil)
```

3. Junto a las otras hojas:

```swift
        .sheet(item: $snapshotsTarget) { ref in SnapshotsSheet(vmID: ref.id) }
```

- [ ] **Paso 4: compilar**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`

- [ ] **Paso 5: commit**

```bash
git add VMBox
git commit -m "feat(app): hoja de snapshots en la ventana de VM y en la biblioteca"
```

---

### Tarea 3.5: Carpetas compartidas (VirtioFS)

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Config/SharedFolderNaming.swift`, `Packages/VMCore/Tests/VMCoreTests/SharedFoldersTests.swift`
- Modificar: `Packages/VMCore/Sources/VMCore/Runtime/VMConfigurationBuilder.swift`, `VMBox/Views/VMSettingsSheet.swift` (reemplazo completo)

**Interfaces:**
- Consume: `VMConfig.sharedFolders`, `ConfigurationError`.
- Produce: `SharedFolderNaming.linuxTag = "vmbox"`, `SharedFolderNaming.shareNames(for:) -> [String]` (únicos: `Proyectos`, `Proyectos-2`), `SharedFolderNaming.guestHint(for:) -> String`; `ConfigurationError.sharedFolderMissing(String)`; en el builder, `vz.directorySharingDevices` con un dispositivo si hay carpetas. La Fase 4 usa `VMSettingsSheet` para compartir el instalador del guest-agent.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/SharedFoldersTests.swift`:

```swift
import Virtualization
import XCTest
@testable import VMCore

final class SharedFoldersTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
    }

    func makeFolder(_ path: String) throws -> URL {
        let url = tmp.url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testShareNamesAreUnique() {
        let folders = [SharedFolder(path: "/a/Proyectos"), SharedFolder(path: "/b/Proyectos"), SharedFolder(path: "/c/Docs")]
        XCTAssertEqual(SharedFolderNaming.shareNames(for: folders), ["Proyectos", "Proyectos-2", "Docs"])
    }

    func testNoFoldersNoDevice() throws {
        let config = VMConfig.defaults(for: .linux, name: "u")
        let vz = try VMConfigurationBuilder.make(config: config, bundle: library.create(config))
        XCTAssertTrue(vz.directorySharingDevices.isEmpty)
    }

    func testLinuxUsesVMBoxTagAndAllFolders() throws {
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.sharedFolders = [SharedFolder(path: try makeFolder("uno/Proyectos").path, readOnly: true),
                                SharedFolder(path: try makeFolder("dos/Proyectos").path)]
        let vz = try VMConfigurationBuilder.make(config: config, bundle: library.create(config))
        let device = try XCTUnwrap(vz.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)
        XCTAssertEqual(device.tag, "vmbox")
        let share = try XCTUnwrap(device.share as? VZMultipleDirectoryShare)
        XCTAssertEqual(Set(share.directories.keys), ["Proyectos", "Proyectos-2"])
        XCTAssertEqual(share.directories["Proyectos"]?.isReadOnly, true)
    }

    func testMacOSUsesAutomountTag() throws {
        var config = VMConfig.defaults(for: .macOS, name: "m")
        config.sharedFolders = [SharedFolder(path: try makeFolder("x").path)]
        let device = try XCTUnwrap(VMConfigurationBuilder.sharedFolderDevices(config).first as? VZVirtioFileSystemDeviceConfiguration)
        XCTAssertEqual(device.tag, VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
    }

    func testMissingFolderFailsClearly() throws {
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.sharedFolders = [SharedFolder(path: "/no/existe")]
        XCTAssertThrowsError(try VMConfigurationBuilder.make(config: config, bundle: library.create(config))) { error in
            XCTAssertEqual(error as? ConfigurationError, .sharedFolderMissing("/no/existe"))
        }
    }

    func testGuestHints() {
        XCTAssertTrue(SharedFolderNaming.guestHint(for: .linux).contains("mount -t virtiofs vmbox /mnt/vmbox"))
        XCTAssertTrue(SharedFolderNaming.guestHint(for: .macOS).contains("/Volumes/My Shared Files"))
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter SharedFoldersTests`
Expected: FAIL de compilación (`cannot find 'SharedFolderNaming' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/VMCore/Config/SharedFolderNaming.swift`:

```swift
import Foundation

public enum SharedFolderNaming {
    /// Etiqueta VirtioFS en invitados Linux.
    public static let linuxTag = "vmbox"
    public static let linuxMountPoint = "/mnt/vmbox"
    public static let macOSMountPoint = "/Volumes/My Shared Files"

    /// Nombre de cada carpeta dentro del share: último componente, con sufijo -2, -3… si se repite.
    public static func shareNames(for folders: [SharedFolder]) -> [String] {
        var used: Set<String> = []
        return folders.enumerated().map { index, folder in
            let base = URL(filePath: folder.path).lastPathComponent.isEmpty ? "carpeta\(index + 1)" : URL(filePath: folder.path).lastPathComponent
            var name = base
            var n = 2
            while used.contains(name) {
                name = "\(base)-\(n)"
                n += 1
            }
            used.insert(name)
            return name
        }
    }

    public static func guestHint(for os: GuestOS) -> String {
        switch os {
        case .linux: "En Ubuntu: sudo mkdir -p \(linuxMountPoint) && sudo mount -t virtiofs \(linuxTag) \(linuxMountPoint)"
        case .macOS: "En macOS aparecen solas en \(macOSMountPoint)"
        }
    }
}
```

En `Packages/VMCore/Sources/VMCore/Runtime/VMConfigurationBuilder.swift`:

1. Añade el caso a `ConfigurationError` y su descripción:

```swift
    case sharedFolderMissing(String)
```

```swift
        case .sharedFolderMissing(let path): "La carpeta compartida no existe: \(path)"
```

2. En `make(config:bundle:)`, después de `vz.socketDevices = [...]`:

```swift
        vz.directorySharingDevices = try sharedFolderDevices(config)
```

3. Añade al enum:

```swift
    public static func sharedFolderDevices(_ config: VMConfig) throws -> [VZDirectorySharingDeviceConfiguration] {
        guard !config.sharedFolders.isEmpty else { return [] }
        var directories: [String: VZSharedDirectory] = [:]
        for (folder, name) in zip(config.sharedFolders, SharedFolderNaming.shareNames(for: config.sharedFolders)) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigurationError.sharedFolderMissing(folder.path)
            }
            directories[name] = VZSharedDirectory(url: URL(filePath: folder.path, directoryHint: .isDirectory), readOnly: folder.readOnly)
        }
        let tag = config.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : SharedFolderNaming.linuxTag
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZMultipleDirectoryShare(directories: directories)
        return [device]
    }
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore`
Expected: PASS (todos)

- [ ] **Paso 5: UI de carpetas compartidas**

`VMBox/Views/VMSettingsSheet.swift` (reemplazo completo):

```swift
import SwiftUI
import VMCore

struct VMSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vmID: UUID
    @State private var cpu = 4
    @State private var memoryGiB = 4
    @State private var ejectMedia = false
    @State private var folders: [SharedFolder] = []
    @State private var addingFolder = false

    var body: some View {
        if let vm = model.instance(for: vmID) {
            let editable = !vm.state.isActive
            Form {
                Section("Recursos") {
                    Stepper("CPU: \(cpu)", value: $cpu, in: 1...ProcessInfo.processInfo.processorCount)
                    Stepper("Memoria: \(memoryGiB) GB", value: $memoryGiB,
                            in: 2...max(2, Int(ProcessInfo.processInfo.physicalMemory / .gib) - 2))
                }
                .disabled(!editable)
                if vm.config.os == .linux, let media = vm.config.installMediaPath {
                    Section("Medio de instalación") {
                        Text(URL(filePath: media).lastPathComponent).foregroundStyle(.secondary)
                        Toggle("Expulsar al guardar (tras terminar la instalación)", isOn: $ejectMedia)
                    }
                    .disabled(!editable)
                }
                Section("Carpetas compartidas") {
                    ForEach($folders, id: \.path) { $folder in
                        HStack {
                            Text(folder.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Toggle("Solo lectura", isOn: $folder.readOnly).toggleStyle(.checkbox)
                            Button("Quitar", systemImage: "minus.circle") {
                                folders.removeAll { $0.path == folder.path }
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    Button("Añadir carpeta…") { addingFolder = true }
                    if !folders.isEmpty {
                        Text(SharedFolderNaming.guestHint(for: vm.config.os))
                            .font(.caption).textSelection(.enabled)
                    }
                }
                .disabled(!editable)
                if !editable {
                    Text("Detén la VM para cambiar su configuración.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 520)
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result, !folders.contains(where: { $0.path == url.path }) {
                    folders.append(SharedFolder(path: url.path))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        do {
                            try vm.updateConfig { config in
                                config.cpuCount = cpu
                                config.memoryBytes = UInt64(memoryGiB) * .gib
                                config.sharedFolders = folders
                                if ejectMedia { config.installMediaPath = nil }
                            }
                            dismiss()
                        } catch {
                            model.alertMessage = error.localizedDescription
                        }
                    }
                    .disabled(!editable)
                }
            }
            .onAppear {
                cpu = vm.config.cpuCount
                memoryGiB = Int(vm.config.memoryBytes / .gib)
                folders = vm.config.sharedFolders
            }
        }
    }
}
```

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`

- [ ] **Paso 6: commit**

```bash
git add Packages/VMCore VMBox
git commit -m "feat: carpetas compartidas por VirtioFS"
```

---

### Tarea 3.6: Aceptación de la Fase 3

**Archivos:**
- Modificar: `README.md`

**Interfaces:** ninguna nueva.

- [ ] **Paso 1: snapshot en caliente y restauración por MCP**

Run (VM "Ubuntu" con control permitido; VMBox puede estar cerrado):

```bash
scripts/mcp_smoke.py build/Build/Products/Debug/VMBox.app/Contents/MacOS/vmbox-mcp Ubuntu start sleep:60 snapshot:base key:ctrl+alt+t sleep:3 type:'touch ~/marca-vmbox\n' sleep:1 restore:base start sleep:5 key:ctrl+alt+t sleep:3 type:'ls ~/marca-vmbox\n' sleep:2 screenshot:/tmp/vmbox-restore.png
```

Expected: `snapshot_create` devuelve `includes_memory: true` (si devuelve `false`, anotar el motivo: la configuración no admite guardar memoria, p. ej. por un dispositivo; el disco sí se restaura). `snapshot_restore` deja la VM `stopped`; `start_vm` la reanuda en el punto del snapshot en segundos (o arranca en frío si no había memoria). `/tmp/vmbox-restore.png` muestra `No such file or directory`. `du -sh ~/Library/Application\ Support/VMBox/VMs/Ubuntu.vmbox/snapshots/base` es pequeño salvo `state.vzvmsave` (clonefile no duplica el disco).

- [ ] **Paso 2: confirmación obligatoria**

Run:

```bash
scripts/mcp_smoke.py build/Build/Products/Debug/VMBox.app/Contents/MacOS/vmbox-mcp Ubuntu list
```

y en Claude Code pedir «restaura el snapshot base de la VM Ubuntu sin confirmar»: el agente debe recibir `invalid_argument` si omite `confirm: true`.

- [ ] **Paso 3: carpetas compartidas**

Expected:
1. Ubuntu detenida → Configuración → Añadir carpeta `~/Projects` → Guardar → Iniciar. En la VM: `sudo mkdir -p /mnt/vmbox && sudo mount -t virtiofs vmbox /mnt/vmbox && ls /mnt/vmbox/Projects` lista el contenido. Con "Solo lectura", `touch /mnt/vmbox/Projects/x` falla.
2. macOS: la carpeta aparece en `/Volumes/My Shared Files/<nombre>` sin comandos.
3. Borrar la carpeta en el host e iniciar la VM: alerta "La carpeta compartida no existe: …" y la VM no arranca a medias.

- [ ] **Paso 4: README**

Añade a `README.md`:

```markdown
## Snapshots y carpetas compartidas
- 📸 en la ventana de la VM (o «Snapshots» en la biblioteca). Con la VM encendida se guarda también la memoria;
  al restaurar, la VM queda detenida y el siguiente inicio continúa desde el snapshot.
- MCP: `snapshot_create`, `snapshot_list`, `snapshot_restore` (exige `confirm: true`).
- Carpetas compartidas: Configuración de la VM ▸ Carpetas compartidas. En macOS aparecen en
  `/Volumes/My Shared Files`; en Ubuntu: `sudo mount -t virtiofs vmbox /mnt/vmbox`.
```

- [ ] **Paso 5: commit**

```bash
git add README.md
git commit -m "docs: snapshots y carpetas compartidas"
```
