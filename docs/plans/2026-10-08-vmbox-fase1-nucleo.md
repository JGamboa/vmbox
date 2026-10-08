# VMBox — Fase 1: núcleo (proyecto, VMCore, crear/iniciar/detener, biblioteca y ventana)

> **Para agentes:** SUB-SKILL REQUERIDO: usa superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar este plan tarea por tarea. Los pasos usan casillas (`- [ ]`). Lee primero el índice [2026-10-08-vmbox-mvp-00-indice.md](2026-10-08-vmbox-mvp-00-indice.md) (restricciones globales, foco de revisión, decisiones de proyecto). **Requisito:** Fase 0 aprobada por el usuario.

**Objetivo:** app VMBox que crea VMs Ubuntu (ISO) y macOS (IPSW), las lista en una biblioteca y las corre en una ventana por VM con ▶︎ ⏸ ⏹.

**Arquitectura:** `Packages/VMCore` (biblioteca `VMCore`) contiene configuración, paquete `.vmbox`, biblioteca, máquina de estados, descargas, construcción de `VZVirtualMachineConfiguration`, creación e instancia en ejecución. La app SwiftUI (`VMBox/`) solo orquesta: `AppModel` + vistas. El proyecto Xcode se genera con XcodeGen.

**Stack:** Swift 6.3, SwiftUI, Virtualization.framework, CryptoKit, XCTest, XcodeGen.

**Spec:** [docs/specs/2026-10-08-vmbox-design.md](../specs/2026-10-08-vmbox-design.md) §3.1–3.3, §4, §6.

## Estructura de archivos de esta fase

```
project.yml
scripts/build.sh, scripts/test.sh
README.md
VMBox/VMBoxApp.swift
VMBox/Model/AppModel.swift
VMBox/Views/LibraryView.swift, NewVMSheet.swift, VMWindowView.swift, VMDisplayView.swift, VMToolbar.swift, VMSettingsSheet.swift
Packages/VMCore/Package.swift
Packages/VMCore/Sources/VMCore/
  Config/VMConfig.swift          VMConfig, GuestOS, SharedFolder, MACAddress
  Config/VMBoxPaths.swift        rutas en Application Support
  Bundle/VMBundle.swift          paquete .vmbox + VMName
  Bundle/VMLibrary.swift         listar/crear/eliminar paquetes
  Runtime/VMState.swift          VMState + VMStateMachine
  Runtime/Policies.swift         StartPolicy (2 macOS) + DiskSpace
  Runtime/VMConfigurationBuilder.swift
  Runtime/VMInstance.swift       VZVirtualMachine + delegado
  Creation/Downloader.swift
  Creation/UbuntuRelease.swift
  Creation/LinuxVMCreator.swift
  Creation/MacOSVMCreator.swift
Packages/VMCore/Tests/VMCoreTests/ (un archivo de test por archivo de producción)
```

---

### Tarea 1.1: Esqueleto del proyecto + `VMConfig`

**Archivos:**
- Crear: `Packages/VMCore/Package.swift`, `Packages/VMCore/Sources/VMCore/Config/VMConfig.swift`, `Packages/VMCore/Sources/VMCore/Config/VMBoxPaths.swift`, `Packages/VMCore/Tests/VMCoreTests/VMConfigTests.swift`, `project.yml`, `VMBox/VMBoxApp.swift`, `scripts/build.sh`, `scripts/test.sh`, `README.md`

**Interfaces:**
- Produce: `GuestOS` (`.macOS` = `"macos"`, `.linux`; `displayName`), `SharedFolder(path:readOnly:)`, `UInt64.gib`, `VMConfig` (campos `id, name, os, cpuCount, memoryBytes, diskBytes, sharedFolders, agentControlEnabled, macAddress, installMediaPath`), `VMConfig.defaults(for:name:)`, `VMConfig.decode(from:)`, `VMConfig.encoded()`, `MACAddress.randomLocallyAdministered() -> String`, `VMBoxPaths.appSupport/.vms/.cache/.mcpLog`.

- [ ] **Paso 1: instalar XcodeGen**

Run: `brew install xcodegen && xcodegen --version`
Expected: `Version: 2.46.0` (o superior)

- [ ] **Paso 2: paquete SwiftPM**

`Packages/VMCore/Package.swift`:

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
    ],
    targets: [
        .target(name: "VMCore"),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
    ]
)
```

- [ ] **Paso 3: test que falla**

`Packages/VMCore/Tests/VMCoreTests/VMConfigTests.swift`:

```swift
import XCTest
@testable import VMCore

final class VMConfigTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let mac = VMConfig.defaults(for: .macOS, name: "m")
        XCTAssertEqual(mac.cpuCount, 4)
        XCTAssertEqual(mac.memoryBytes, 8 * .gib)
        XCTAssertEqual(mac.diskBytes, 80 * .gib)
        let linux = VMConfig.defaults(for: .linux, name: "u")
        XCTAssertEqual(linux.cpuCount, 4)
        XCTAssertEqual(linux.memoryBytes, 4 * .gib)
        XCTAssertEqual(linux.diskBytes, 40 * .gib)
        XCTAssertFalse(linux.agentControlEnabled)
        XCTAssertTrue(linux.sharedFolders.isEmpty)
    }

    func testRoundTrip() throws {
        var config = VMConfig.defaults(for: .linux, name: "Ubuntu")
        config.sharedFolders = [SharedFolder(path: "/tmp/x", readOnly: true)]
        config.agentControlEnabled = true
        config.installMediaPath = "/tmp/u.iso"
        XCTAssertEqual(try VMConfig.decode(from: config.encoded()), config)
    }

    func testEncodesOSAsLowercaseString() throws {
        let json = String(decoding: try VMConfig.defaults(for: .macOS, name: "m").encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"os\" : \"macos\""), json)
    }

    /// Foco de revisión 5: config.json antiguo o editado a mano sin claves opcionales.
    func testMissingOptionalKeysUseDefaults() throws {
        let json = """
        {"id":"8C1F7E8E-2F7B-4C1B-9E1A-7D3F0B6B9A10","name":"vieja","os":"linux","cpuCount":2,
         "memoryBytes":2147483648,"diskBytes":10737418240,"macAddress":"02:00:00:00:00:01"}
        """
        let config = try VMConfig.decode(from: Data(json.utf8))
        XCTAssertFalse(config.agentControlEnabled)
        XCTAssertEqual(config.sharedFolders, [])
        XCTAssertNil(config.installMediaPath)
    }

    func testRandomMACIsLocallyAdministeredUnicast() throws {
        for _ in 0..<50 {
            let mac = MACAddress.randomLocallyAdministered()
            XCTAssertNotNil(mac.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression), mac)
            let first = try XCTUnwrap(UInt8(mac.prefix(2), radix: 16))
            XCTAssertEqual(first & 0b11, 0b10, "bit local=1, bit multicast=0")
        }
    }
}
```

- [ ] **Paso 4: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter VMConfigTests`
Expected: FAIL de compilación (`cannot find 'VMConfig' in scope`)

- [ ] **Paso 5: implementación**

`Packages/VMCore/Sources/VMCore/Config/VMConfig.swift`:

```swift
import Foundation

public enum GuestOS: String, Codable, Sendable, CaseIterable {
    case macOS = "macos"
    case linux

    public var displayName: String { self == .macOS ? "macOS" : "Ubuntu" }
}

public struct SharedFolder: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool = false) {
        self.path = path
        self.readOnly = readOnly
    }
}

public extension UInt64 {
    static let gib: UInt64 = 1 << 30
}

public enum MACAddress {
    /// MAC unicast administrada localmente (bit 1 del primer byte = 1, bit 0 = 0).
    public static func randomLocallyAdministered() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0b1111_1100) | 0b10
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

public struct VMConfig: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var os: GuestOS
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var sharedFolders: [SharedFolder]
    public var agentControlEnabled: Bool
    public var macAddress: String
    /// ISO de instalación conectada como disco USB (solo Linux). `nil` = sin medio.
    public var installMediaPath: String?

    public init(
        id: UUID = UUID(), name: String, os: GuestOS, cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64,
        sharedFolders: [SharedFolder] = [], agentControlEnabled: Bool = false,
        macAddress: String = MACAddress.randomLocallyAdministered(), installMediaPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.os = os
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.sharedFolders = sharedFolders
        self.agentControlEnabled = agentControlEnabled
        self.macAddress = macAddress
        self.installMediaPath = installMediaPath
    }

    public static func defaults(for os: GuestOS, name: String) -> VMConfig {
        switch os {
        case .macOS: VMConfig(name: name, os: .macOS, cpuCount: 4, memoryBytes: 8 * .gib, diskBytes: 80 * .gib)
        case .linux: VMConfig(name: name, os: .linux, cpuCount: 4, memoryBytes: 4 * .gib, diskBytes: 40 * .gib)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, os, cpuCount, memoryBytes, diskBytes, sharedFolders, agentControlEnabled, macAddress, installMediaPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(GuestOS.self, forKey: .os)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
        diskBytes = try c.decode(UInt64.self, forKey: .diskBytes)
        macAddress = try c.decode(String.self, forKey: .macAddress)
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        agentControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentControlEnabled) ?? false
        installMediaPath = try c.decodeIfPresent(String.self, forKey: .installMediaPath)
    }

    public static func decode(from data: Data) throws -> VMConfig {
        try JSONDecoder().decode(VMConfig.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
```

`Packages/VMCore/Sources/VMCore/Config/VMBoxPaths.swift`:

```swift
import Foundation

public enum VMBoxPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VMBox", directoryHint: .isDirectory)
    }
    public static var vms: URL { appSupport.appending(path: "VMs", directoryHint: .isDirectory) }
    public static var cache: URL { appSupport.appending(path: "Cache", directoryHint: .isDirectory) }
    public static var mcpLog: URL { appSupport.appending(path: "mcp.log") }
}
```

- [ ] **Paso 6: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter VMConfigTests`
Expected: PASS (5 tests)

- [ ] **Paso 7: proyecto Xcode, app mínima y scripts**

`project.yml`:

```yaml
name: VMBox
options:
  bundleIdPrefix: cl.multiapi
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "26.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: ""
    ENABLE_HARDENED_RUNTIME: NO
packages:
  VMCore:
    path: Packages/VMCore
targets:
  VMBox:
    type: application
    platform: macOS
    sources: [VMBox]
    entitlements:
      path: VMBox/VMBox.entitlements
      properties:
        com.apple.security.virtualization: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: cl.multiapi.vmbox
        PRODUCT_NAME: VMBox
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: VMBox
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.developer-tools
        ENABLE_APP_SANDBOX: NO
    dependencies:
      - package: VMCore
        products: [VMCore]
schemes:
  VMBox:
    build:
      targets:
        VMBox: all
    run:
      config: Debug
```

`VMBox/VMBoxApp.swift` (provisional; la Tarea 1.8 lo reemplaza):

```swift
import SwiftUI
import VMCore

@main
struct VMBoxApp: App {
    var body: some Scene {
        Window("VMBox", id: "library") {
            Text("VMBox — biblioteca en \(VMBoxPaths.vms.path)")
                .padding()
        }
    }
}
```

`scripts/build.sh`:

```bash
#!/bin/bash
# Genera el proyecto con XcodeGen y compila VMBox (Debug) en ./build.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project VMBox.xcodeproj -scheme VMBox -configuration Debug \
  -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation build \
  | grep -E "error:|warning: .*VMBox|BUILD (SUCCEEDED|FAILED)" || true
test -d build/Build/Products/Debug/VMBox.app
echo "OK: build/Build/Products/Debug/VMBox.app"
```

`scripts/test.sh`:

```bash
#!/bin/bash
# Tests unitarios de todo el repo.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/VMCore
```

`README.md`:

````markdown
# VMBox

App de macOS para correr VMs de macOS y Ubuntu (Virtualization.framework) controlables por agentes vía MCP.
Diseño: `docs/specs/2026-10-08-vmbox-design.md`. Plan: `docs/plans/`.

## Requisitos
Apple silicon, macOS 26, Xcode 26, `brew install xcodegen`.

## Compilar y probar
```bash
scripts/test.sh
scripts/build.sh
open build/Build/Products/Debug/VMBox.app
```
````

Run: `chmod +x scripts/*.sh && scripts/build.sh`
Expected: `BUILD SUCCEEDED` y `OK: build/Build/Products/Debug/VMBox.app`

- [ ] **Paso 8: verificar firma y entitlement**

Run: `codesign -d --entitlements - build/Build/Products/Debug/VMBox.app 2>&1 | grep -A1 virtualization`
Expected: muestra `com.apple.security.virtualization` con valor `true`.

Run: `open build/Build/Products/Debug/VMBox.app`
Expected: ventana "VMBox" con la ruta de la biblioteca.

- [ ] **Paso 9: commit**

```bash
git add project.yml VMBox Packages scripts README.md
git commit -m "feat: esqueleto de VMBox (XcodeGen + paquete VMCore) y VMConfig"
```

---

### Tarea 1.2: Paquete `.vmbox` y biblioteca

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Bundle/VMBundle.swift`, `Packages/VMCore/Sources/VMCore/Bundle/VMLibrary.swift`, `Packages/VMCore/Tests/VMCoreTests/TestSupport.swift`, `Packages/VMCore/Tests/VMCoreTests/VMLibraryTests.swift`

**Interfaces:**
- Consume: `VMConfig`, `VMBoxPaths.vms`.
- Produce:
  - `VMName.validate(_ name: String) throws -> String` (devuelve el nombre recortado).
  - `VMBundle` con `url`, `configURL`, `diskURL`, `auxURL`, `hardwareModelURL`, `machineIdURL`, `nvramURL`, `snapshotsURL`, `readConfig() throws -> VMConfig`, `writeConfig(_:) throws`, `allocatedBytes() -> UInt64`, `static let fileExtension = "vmbox"`.
  - `VMBundleError` (`invalidName(String)`, `alreadyExists(String)`).
  - `VMEntry { bundle, config, diskUsageBytes, id }`, `VMLibraryListing { entries, broken }`.
  - `VMLibrary(root:)` con `ensureRoot()`, `list() throws -> VMLibraryListing`, `create(_ config:) throws -> VMBundle`, `create(_ config:, populate: @MainActor (VMBundle) async throws -> Void) async throws -> VMBundle` (borra el paquete si `populate` falla), `remove(_:) throws`, `static var defaultRoot`.
  - En tests: `TemporaryDirectory` (crea y borra un directorio temporal).

- [ ] **Paso 1: soporte de tests**

`Packages/VMCore/Tests/VMCoreTests/TestSupport.swift`:

```swift
import Foundation

/// Directorio temporal único que se borra al liberar el objeto.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "vmcore-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: Data = Data()) throws -> URL {
        let file = url.appending(path: name)
        try contents.write(to: file)
        return file
    }
}
```

- [ ] **Paso 2: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/VMLibraryTests.swift`:

```swift
import XCTest
@testable import VMCore

final class VMLibraryTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
    }

    func testCreateWritesConfigAndSparseDisk() throws {
        let config = VMConfig.defaults(for: .linux, name: "Ubuntu")
        let bundle = try library.create(config)
        XCTAssertEqual(bundle.url.lastPathComponent, "Ubuntu.vmbox")
        XCTAssertEqual(try bundle.readConfig(), config)
        let attributes = try FileManager.default.attributesOfItem(atPath: bundle.diskURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, 40 * .gib)
        let allocated = try bundle.diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? .max
        XCTAssertLessThan(allocated, 1 << 20, "disk.img debe ser sparse")
    }

    func testListReturnsEntriesSortedByName() throws {
        _ = try library.create(.defaults(for: .linux, name: "zeta"))
        _ = try library.create(.defaults(for: .macOS, name: "Alfa"))
        let listing = try library.list()
        XCTAssertEqual(listing.entries.map(\.config.name), ["Alfa", "zeta"])
        XCTAssertEqual(listing.broken, [])
    }

    func testListOnMissingRootIsEmpty() throws {
        XCTAssertEqual(try library.list().entries.count, 0)
    }

    /// Foco de revisión 5: un paquete corrupto no rompe la biblioteca.
    func testCorruptBundleIsReportedNotFatal() throws {
        _ = try library.create(.defaults(for: .linux, name: "buena"))
        let bad = library.root.appending(path: "mala.vmbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{no es json".utf8).write(to: bad.appending(path: "config.json"))
        let listing = try library.list()
        XCTAssertEqual(listing.entries.map(\.config.name), ["buena"])
        XCTAssertEqual(listing.broken.map(\.lastPathComponent), ["mala.vmbox"])
    }

    /// Foco de revisión 5: nombres inválidos.
    func testRejectsInvalidNames() {
        for name in ["", "   ", "a/b", "a:b", ".oculta", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try library.create(.defaults(for: .linux, name: name)), name) { error in
                guard case VMBundleError.invalidName = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRejectsDuplicateNamesCaseInsensitively() throws {
        _ = try library.create(.defaults(for: .linux, name: "Ubuntu"))
        XCTAssertThrowsError(try library.create(.defaults(for: .linux, name: "ubuntu"))) { error in
            XCTAssertEqual(error as? VMBundleError, .alreadyExists("ubuntu"))
        }
    }

    func testTrimsName() throws {
        let bundle = try library.create(.defaults(for: .linux, name: "  Ubuntu  "))
        XCTAssertEqual(try bundle.readConfig().name, "Ubuntu")
    }

    func testWriteConfigPersists() throws {
        let bundle = try library.create(.defaults(for: .linux, name: "u"))
        var config = try bundle.readConfig()
        config.agentControlEnabled = true
        try bundle.writeConfig(config)
        XCTAssertTrue(try bundle.readConfig().agentControlEnabled)
    }

    /// Foco de revisión 4: una creación que falla no deja un paquete a medias.
    func testFailedPopulateRemovesBundle() async throws {
        struct Boom: Error {}
        do {
            _ = try await library.create(.defaults(for: .macOS, name: "mac")) { _ in throw Boom() }
            XCTFail("debió lanzar")
        } catch is Boom {}
        XCTAssertEqual(try library.list().entries.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appending(path: "mac.vmbox").path))
    }
}
```

- [ ] **Paso 3: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter VMLibraryTests`
Expected: FAIL de compilación (`cannot find 'VMLibrary' in scope`)

- [ ] **Paso 4: implementación**

`Packages/VMCore/Sources/VMCore/Bundle/VMBundle.swift`:

```swift
import Foundation

public enum VMBundleError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "Nombre de VM inválido: «\(name)». Usa 1–64 caracteres, sin «/» ni «:» y sin empezar con «.»."
        case .alreadyExists(let name): "Ya existe una VM llamada «\(name)»."
        }
    }
}

public enum VMName {
    public static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw VMBundleError.invalidName(raw)
        }
        return name
    }
}

public struct VMBundle: Sendable, Equatable {
    public static let fileExtension = "vmbox"
    public let url: URL

    public init(url: URL) { self.url = url }

    public var configURL: URL { url.appending(path: "config.json") }
    public var diskURL: URL { url.appending(path: "disk.img") }
    public var auxURL: URL { url.appending(path: "aux.img") }
    public var hardwareModelURL: URL { url.appending(path: "hardware-model.bin") }
    public var machineIdURL: URL { url.appending(path: "machine-id.bin") }
    public var nvramURL: URL { url.appending(path: "nvram.bin") }
    public var snapshotsURL: URL { url.appending(path: "snapshots", directoryHint: .isDirectory) }

    public func readConfig() throws -> VMConfig {
        try VMConfig.decode(from: Data(contentsOf: configURL))
    }

    public func writeConfig(_ config: VMConfig) throws {
        try config.encoded().write(to: configURL, options: .atomic)
    }

    /// Bytes realmente ocupados en disco por todo el paquete (archivos sparse cuentan lo usado).
    public func allocatedBytes() -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            total += UInt64((try? file.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
```

`Packages/VMCore/Sources/VMCore/Bundle/VMLibrary.swift`:

```swift
import Foundation

public struct VMEntry: Sendable, Identifiable {
    public var bundle: VMBundle
    public var config: VMConfig
    public var diskUsageBytes: UInt64
    public var id: UUID { config.id }
}

public struct VMLibraryListing: Sendable {
    public var entries: [VMEntry]
    public var broken: [URL]
}

public struct VMLibrary: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL { VMBoxPaths.vms }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func list() throws -> VMLibraryListing {
        guard FileManager.default.fileExists(atPath: root.path) else { return VMLibraryListing(entries: [], broken: []) }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == VMBundle.fileExtension }
        var entries: [VMEntry] = []
        var broken: [URL] = []
        for url in urls {
            let bundle = VMBundle(url: url)
            if let config = try? bundle.readConfig() {
                entries.append(VMEntry(bundle: bundle, config: config, diskUsageBytes: bundle.allocatedBytes()))
            } else {
                broken.append(url)
            }
        }
        entries.sort { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
        broken.sort { $0.lastPathComponent < $1.lastPathComponent }
        return VMLibraryListing(entries: entries, broken: broken)
    }

    /// Crea `<nombre>.vmbox` con `config.json` y `disk.img` sparse del tamaño configurado.
    public func create(_ config: VMConfig) throws -> VMBundle {
        var config = config
        config.name = try VMName.validate(config.name)
        try ensureRoot()
        let existing = try list()
        let taken = existing.entries.map { $0.config.name.lowercased() }
            + existing.broken.map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        guard !taken.contains(config.name.lowercased()) else { throw VMBundleError.alreadyExists(config.name) }

        let bundle = VMBundle(url: root.appending(path: "\(config.name).\(VMBundle.fileExtension)", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: false)
        do {
            try bundle.writeConfig(config)
            FileManager.default.createFile(atPath: bundle.diskURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: bundle.diskURL)
            try handle.truncate(atOffset: config.diskBytes)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
        return bundle
    }

    /// Crea el paquete y ejecuta `populate` en el hilo principal (Virtualization lo exige);
    /// si `populate` falla, el paquete se borra.
    public func create(_ config: VMConfig, populate: @MainActor (VMBundle) async throws -> Void) async throws -> VMBundle {
        let bundle = try create(config)
        do {
            try await populate(bundle)
        } catch {
            try? remove(bundle)
            throw error
        }
        return bundle
    }

    public func remove(_ bundle: VMBundle) throws {
        try FileManager.default.removeItem(at: bundle.url)
    }
}
```

- [ ] **Paso 5: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter VMLibraryTests`
Expected: PASS (9 tests)

- [ ] **Paso 6: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): paquete .vmbox y biblioteca de VMs"
```

---

### Tarea 1.3: Máquina de estados y políticas (límite macOS, espacio libre)

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Runtime/VMState.swift`, `Packages/VMCore/Sources/VMCore/Runtime/Policies.swift`, `Packages/VMCore/Tests/VMCoreTests/VMStateMachineTests.swift`, `Packages/VMCore/Tests/VMCoreTests/PoliciesTests.swift`

**Interfaces:**
- Produce:
  - `VMState` (`stopped, starting, running, paused, stopping, error`; `displayName`, `isActive`).
  - `VMStateEvent` (`startRequested, startSucceeded, pauseSucceeded, resumeSucceeded, stopRequested, stopAbandoned`).
  - `VMStateMachine` con `state`, `lastError`, `apply(_:) throws`, `markStopped()`, `fail(_:)`; `VMStateError.invalidTransition(from:event:)`.
  - `StartPolicy.maxConcurrentMacOS = 2`, `StartPolicy.check(starting:running:) -> StartCheck` (`.ok`, `.macOSLimitReached`).
  - `DiskSpace.available(at:) throws -> UInt64`, `DiskSpace.ensure(_ required:, available:) throws`, `DiskSpace.requiredForCreate(_ os:) -> UInt64`, `DiskSpaceError.insufficient(required:available:)`.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/VMStateMachineTests.swift`:

```swift
import XCTest
@testable import VMCore

final class VMStateMachineTests: XCTestCase {
    func testHappyPath() throws {
        var m = VMStateMachine()
        XCTAssertEqual(m.state, .stopped)
        try m.apply(.startRequested); XCTAssertEqual(m.state, .starting)
        try m.apply(.startSucceeded); XCTAssertEqual(m.state, .running)
        try m.apply(.pauseSucceeded); XCTAssertEqual(m.state, .paused)
        try m.apply(.resumeSucceeded); XCTAssertEqual(m.state, .running)
        try m.apply(.stopRequested); XCTAssertEqual(m.state, .stopping)
        m.markStopped(); XCTAssertEqual(m.state, .stopped)
    }

    func testInvalidTransitionThrows() {
        var m = VMStateMachine()
        XCTAssertThrowsError(try m.apply(.pauseSucceeded)) { error in
            XCTAssertEqual(error as? VMStateError, .invalidTransition(from: .stopped, event: .pauseSucceeded))
        }
        XCTAssertEqual(m.state, .stopped)
    }

    func testCannotStartTwice() throws {
        var m = VMStateMachine()
        try m.apply(.startRequested)
        XCTAssertThrowsError(try m.apply(.startRequested))
    }

    func testFailureRecordsMessageAndAllowsRestart() throws {
        var m = VMStateMachine()
        try m.apply(.startRequested)
        m.fail("sin memoria")
        XCTAssertEqual(m.state, .error)
        XCTAssertEqual(m.lastError, "sin memoria")
        try m.apply(.startRequested)
        XCTAssertEqual(m.state, .starting)
        XCTAssertNil(m.lastError)
    }

    func testStopAbandonedReturnsToRunning() throws {
        var m = VMStateMachine()
        try m.apply(.startRequested); try m.apply(.startSucceeded); try m.apply(.stopRequested)
        try m.apply(.stopAbandoned)
        XCTAssertEqual(m.state, .running)
    }

    func testIsActive() {
        XCTAssertFalse(VMState.stopped.isActive)
        XCTAssertFalse(VMState.error.isActive)
        XCTAssertTrue(VMState.running.isActive)
        XCTAssertTrue(VMState.paused.isActive)
        XCTAssertTrue(VMState.starting.isActive)
    }
}
```

`Packages/VMCore/Tests/VMCoreTests/PoliciesTests.swift`:

```swift
import XCTest
@testable import VMCore

final class PoliciesTests: XCTestCase {
    func testThirdMacOSIsRejected() {
        XCTAssertEqual(StartPolicy.check(starting: .macOS, running: [.macOS]), .ok)
        XCTAssertEqual(StartPolicy.check(starting: .macOS, running: [.macOS, .macOS]), .macOSLimitReached)
        XCTAssertEqual(StartPolicy.check(starting: .linux, running: [.macOS, .macOS, .linux]), .ok)
    }

    func testEnsureThrowsWhenInsufficient() {
        XCTAssertNoThrow(try DiskSpace.ensure(10, available: 10))
        XCTAssertThrowsError(try DiskSpace.ensure(11, available: 10)) { error in
            XCTAssertEqual(error as? DiskSpaceError, .insufficient(required: 11, available: 10))
        }
    }

    func testAvailableReadsVolume() throws {
        XCTAssertGreaterThan(try DiskSpace.available(at: FileManager.default.temporaryDirectory), 0)
    }

    func testRequiredForCreate() {
        XCTAssertEqual(DiskSpace.requiredForCreate(.macOS), 50 * .gib)
        XCTAssertEqual(DiskSpace.requiredForCreate(.linux), 15 * .gib)
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter "VMStateMachineTests|PoliciesTests"`
Expected: FAIL de compilación (`cannot find 'VMStateMachine' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/VMCore/Runtime/VMState.swift`:

```swift
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

public enum VMStateError: Error, Equatable {
    case invalidTransition(from: VMState, event: VMStateEvent)
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
```

`Packages/VMCore/Sources/VMCore/Runtime/Policies.swift`:

```swift
import Foundation

public enum StartCheck: Equatable, Sendable { case ok, macOSLimitReached }

public enum StartPolicy {
    /// Límite de Apple para invitados macOS simultáneos en un mismo host.
    public static let maxConcurrentMacOS = 2

    public static func check(starting os: GuestOS, running: [GuestOS]) -> StartCheck {
        guard os == .macOS else { return .ok }
        return running.filter { $0 == .macOS }.count >= maxConcurrentMacOS ? .macOSLimitReached : .ok
    }
}

public enum DiskSpaceError: Error, Equatable, LocalizedError {
    case insufficient(required: UInt64, available: UInt64)

    public var errorDescription: String? {
        switch self {
        case let .insufficient(required, available):
            let f = ByteCountFormatter()
            return "Espacio libre insuficiente: se necesitan \(f.string(fromByteCount: Int64(required))) y hay \(f.string(fromByteCount: Int64(available)))."
        }
    }
}

public enum DiskSpace {
    public static func available(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    public static func ensure(_ required: UInt64, available: UInt64) throws {
        guard available >= required else { throw DiskSpaceError.insufficient(required: required, available: available) }
    }

    /// Margen para descargar el medio e instalar: IPSW ≈18 GB + sistema; ISO ≈4 GB + sistema.
    public static func requiredForCreate(_ os: GuestOS) -> UInt64 {
        os == .macOS ? 50 * .gib : 15 * .gib
    }
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter "VMStateMachineTests|PoliciesTests"`
Expected: PASS (10 tests)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): máquina de estados, límite de VMs macOS y espacio libre"
```

---

### Tarea 1.4: Construcción de `VZVirtualMachineConfiguration`

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Runtime/VMConfigurationBuilder.swift`, `Packages/VMCore/Tests/VMCoreTests/VMConfigurationBuilderTests.swift`

**Interfaces:**
- Consume: `VMConfig`, `VMBundle`, `VMLibrary` (en tests).
- Produce: `VMConfigurationBuilder.make(config:bundle:) throws -> VZVirtualMachineConfiguration` (sin validar, para tests) y `VMConfigurationBuilder.build(config:bundle:)` (`make` + `validate()`, para la app), `VMConfigurationBuilder.displayWidth/displayHeight` (1920×1200), `ConfigurationError` (`missingFile(String)`, `invalidPlatformData(String)`, `invalidMACAddress(String)`). La Fase 3 añade carpetas compartidas aquí.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/VMConfigurationBuilderTests.swift`:

```swift
import Virtualization
import XCTest
@testable import VMCore

final class VMConfigurationBuilderTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
    }

    func testLinuxConfigurationCreatesPlatformFiles() throws {
        let config = VMConfig.defaults(for: .linux, name: "u")
        let bundle = try library.create(config)
        let vz = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        XCTAssertEqual(vz.cpuCount, 4)
        XCTAssertEqual(vz.memorySize, 4 * .gib)
        XCTAssertEqual(vz.storageDevices.count, 1)
        XCTAssertTrue(vz.bootLoader is VZEFIBootLoader)
        XCTAssertEqual(vz.socketDevices.count, 1)
        XCTAssertEqual(vz.networkDevices.first?.macAddress.string, config.macAddress)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.nvramURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.machineIdURL.path))
    }

    func testMachineIdentifierIsStableAcrossBuilds() throws {
        let config = VMConfig.defaults(for: .linux, name: "u")
        let bundle = try library.create(config)
        _ = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        let first = try Data(contentsOf: bundle.machineIdURL)
        _ = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        XCTAssertEqual(try Data(contentsOf: bundle.machineIdURL), first)
    }

    func testInstallMediaAddsUSBDevice() throws {
        let iso = try tmp.file("u.iso", contents: Data(count: 1 << 20))
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.installMediaPath = iso.path
        let bundle = try library.create(config)
        let vz = try VMConfigurationBuilder.make(config: config, bundle: bundle)
        XCTAssertEqual(vz.storageDevices.count, 2)
        XCTAssertTrue(vz.storageDevices.last is VZUSBMassStorageDeviceConfiguration)
    }

    func testMissingInstallMediaThrows() throws {
        var config = VMConfig.defaults(for: .linux, name: "u")
        config.installMediaPath = "/no/existe.iso"
        let bundle = try library.create(config)
        XCTAssertThrowsError(try VMConfigurationBuilder.make(config: config, bundle: bundle)) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingFile("/no/existe.iso"))
        }
    }

    func testMacOSWithoutPlatformFilesThrows() throws {
        let config = VMConfig.defaults(for: .macOS, name: "m")
        let bundle = try library.create(config)
        XCTAssertThrowsError(try VMConfigurationBuilder.make(config: config, bundle: bundle)) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingFile(bundle.hardwareModelURL.path))
        }
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter VMConfigurationBuilderTests`
Expected: FAIL de compilación (`cannot find 'VMConfigurationBuilder' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/VMCore/Runtime/VMConfigurationBuilder.swift`:

```swift
import Foundation
import Virtualization

public enum ConfigurationError: Error, Equatable, LocalizedError {
    case missingFile(String)
    case invalidPlatformData(String)
    case invalidMACAddress(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path): "Falta el archivo \(path)"
        case .invalidPlatformData(let path): "Datos de plataforma inválidos en \(path)"
        case .invalidMACAddress(let mac): "MAC inválida: \(mac)"
        }
    }
}

public enum VMConfigurationBuilder {
    public static let displayWidth = 1920
    public static let displayHeight = 1200

    /// Configuración validada, lista para `VZVirtualMachine`. `validate()` exige el entitlement
    /// de virtualización en el proceso, por eso los tests usan `make` y la app usa `build`.
    public static func build(config: VMConfig, bundle: VMBundle) throws -> VZVirtualMachineConfiguration {
        let vz = try make(config: config, bundle: bundle)
        try vz.validate()
        return vz
    }

    /// Construye la configuración sin validarla.
    public static func make(config: VMConfig, bundle: VMBundle) throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vz.memorySize = min(max(config.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        switch config.os {
        case .linux: try configureLinux(vz, config: config, bundle: bundle)
        case .macOS: try configureMacOS(vz, bundle: bundle)
        }
        vz.networkDevices = [try network(config)]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        return vz
    }

    private static func configureLinux(_ vz: VZVirtualMachineConfiguration, config: VMConfig, bundle: VMBundle) throws {
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try genericMachineIdentifier(bundle)
        vz.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = FileManager.default.fileExists(atPath: bundle.nvramURL.path)
            ? VZEFIVariableStore(url: bundle.nvramURL)
            : try VZEFIVariableStore(creatingVariableStoreAt: bundle.nvramURL)
        vz.bootLoader = bootLoader

        var storage: [VZStorageDeviceConfiguration] = [try disk(bundle)]
        if let iso = config.installMediaPath {
            guard FileManager.default.fileExists(atPath: iso) else { throw ConfigurationError.missingFile(iso) }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: iso), readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        vz.storageDevices = storage

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: displayWidth, heightInPixels: displayHeight)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private static func configureMacOS(_ vz: VZVirtualMachineConfiguration, bundle: VMBundle) throws {
        let platform = VZMacPlatformConfiguration()
        let hardwareData = try read(bundle.hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData), hardwareModel.isSupported else {
            throw ConfigurationError.invalidPlatformData(bundle.hardwareModelURL.path)
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: try read(bundle.machineIdURL)) else {
            throw ConfigurationError.invalidPlatformData(bundle.machineIdURL.path)
        }
        guard FileManager.default.fileExists(atPath: bundle.auxURL.path) else {
            throw ConfigurationError.missingFile(bundle.auxURL.path)
        }
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxURL)
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()
        vz.storageDevices = [try disk(bundle)]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: displayWidth, heightInPixels: displayHeight, pixelsPerInch: 144)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZMacKeyboardConfiguration()]
        vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private static func disk(_ bundle: VMBundle) throws -> VZVirtioBlockDeviceConfiguration {
        VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false))
    }

    private static func network(_ config: VMConfig) throws -> VZVirtioNetworkDeviceConfiguration {
        guard let mac = VZMACAddress(string: config.macAddress) else { throw ConfigurationError.invalidMACAddress(config.macAddress) }
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        device.macAddress = mac
        return device
    }

    private static func genericMachineIdentifier(_ bundle: VMBundle) throws -> VZGenericMachineIdentifier {
        if FileManager.default.fileExists(atPath: bundle.machineIdURL.path) {
            guard let identifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineIdURL)) else {
                throw ConfigurationError.invalidPlatformData(bundle.machineIdURL.path)
            }
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: bundle.machineIdURL)
        return identifier
    }

    private static func read(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ConfigurationError.missingFile(url.path) }
        return try Data(contentsOf: url)
    }
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter VMConfigurationBuilderTests`
Expected: PASS (5 tests). (Verificado al escribir el plan: `validate()` falla bajo `swift test` porque el proceso `xctest` no tiene el entitlement de virtualización y firmar el bundle de tests no lo cambia; por eso los tests usan `make` y la validación real ocurre en la app, Tareas 1.6 y 1.9.)

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): construir VZVirtualMachineConfiguration para Linux y macOS"
```

---

### Tarea 1.5: Descargas reanudables con reintentos y SHA256

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Creation/Downloader.swift`, `Packages/VMCore/Tests/VMCoreTests/StubURLProtocol.swift`, `Packages/VMCore/Tests/VMCoreTests/DownloaderTests.swift`

**Interfaces:**
- Produce: `DownloadRequest(url:destination:expectedSHA256:)`, `DownloadError` (`httpStatus(Int)`, `checksumMismatch(expected:actual:)`), `Downloader(session:maxAttempts:retryDelay:)` con `download(_:progress:) async throws -> URL`, `Downloader.partialURL(for:)`, `Downloader.sha256(of:) throws -> String`. En tests: `StubURLProtocol` (`handler`, `requests`, `session()`, `reset()`).

- [ ] **Paso 1: stub de red para tests**

`Packages/VMCore/Tests/VMCoreTests/StubURLProtocol.swift`:

```swift
import Foundation

/// URLProtocol que responde con lo que devuelva `handler`. Los tests de XCTest corren en serie.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
        /// Content-Length anunciado; por defecto, el tamaño real de `body`.
        var declaredLength: Int?
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let reply = Self.handler?(request) ?? Reply(status: 500)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var headers = reply.headers
        headers["Content-Length"] = "\(reply.declaredLength ?? reply.body.count)"
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Paso 2: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/DownloaderTests.swift`:

```swift
import CryptoKit
import XCTest
@testable import VMCore

final class DownloaderTests: XCTestCase {
    var tmp: TemporaryDirectory!
    let body = Data("contenido de prueba de VMBox".utf8)
    let url = URL(string: "https://example.test/archivo.iso")!
    var sha: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    var destination: URL { tmp.url.appending(path: "archivo.iso") }

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        StubURLProtocol.reset()
    }

    func makeDownloader(maxAttempts: Int = 3, retryDelay: Duration = .zero) -> Downloader {
        Downloader(session: StubURLProtocol.session(), maxAttempts: maxAttempts, retryDelay: retryDelay)
    }

    func testDownloadsAndVerifiesChecksum() async throws {
        StubURLProtocol.handler = { _ in .init(body: self.body) }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(try Data(contentsOf: result), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path))
    }

    /// Foco de revisión 4: SHA256 incorrecto no deja archivo final ni parcial.
    func testChecksumMismatchLeavesNothing() async throws {
        StubURLProtocol.handler = { _ in .init(body: self.body) }
        do {
            _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: String(repeating: "0", count: 64)))
            XCTFail("debió lanzar")
        } catch DownloadError.checksumMismatch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path))
    }

    /// Foco de revisión 4: una descarga cortada se reanuda con Range.
    func testResumesFromPartialFileWithRange() async throws {
        try body.prefix(5).write(to: Downloader.partialURL(for: destination))
        StubURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=5-" {
                return .init(status: 206, body: self.body.dropFirst(5))
            }
            return .init(body: self.body)
        }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(try Data(contentsOf: result), body)
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=5-")
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        try Data("basura".utf8).write(to: Downloader.partialURL(for: destination))
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.body) }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(try Data(contentsOf: result), body)
    }

    /// Spec §6: validación de tamaño (el IPSW no publica SHA256). Llega menos de lo anunciado → reanuda.
    func testShortBodyIsResumed() async throws {
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            if calls == 1 { return .init(body: self.body.prefix(5), declaredLength: self.body.count) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=5-")
            return .init(status: 206, body: self.body.dropFirst(5))
        }
        let result = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: nil))
        XCTAssertEqual(try Data(contentsOf: result), body)
        XCTAssertEqual(calls, 2)
    }

    func testRetriesTransientErrors() async throws {
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            return calls < 3 ? .init(error: URLError(.networkConnectionLost)) : .init(body: self.body)
        }
        _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(calls, 3)
    }

    func testGivesUpAfterThreeAttemptsAndKeepsPartial() async throws {
        StubURLProtocol.handler = { _ in .init(error: URLError(.networkConnectionLost)) }
        do {
            _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: nil))
            XCTFail("debió lanzar")
        } catch {}
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path), "el parcial queda para reanudar")
    }

    func testClientErrorIsNotRetried() async throws {
        StubURLProtocol.handler = { _ in .init(status: 404) }
        do {
            _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: nil))
            XCTFail("debió lanzar")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .httpStatus(404))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    /// Foco de revisión 4: cancelar borra el parcial.
    func testCancellationRemovesPartial() async throws {
        StubURLProtocol.handler = { _ in .init(error: URLError(.networkConnectionLost)) }
        let downloader = makeDownloader(retryDelay: .seconds(10))
        let request = DownloadRequest(url: url, destination: destination, expectedSHA256: nil)
        let task = Task { try await downloader.download(request) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("debió lanzar")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloader.partialURL(for: destination).path))
    }

    func testExistingVerifiedFileSkipsNetwork() async throws {
        try body.write(to: destination)
        _ = try await makeDownloader().download(.init(url: url, destination: destination, expectedSHA256: sha))
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }
}
```

- [ ] **Paso 3: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter DownloaderTests`
Expected: FAIL de compilación (`cannot find 'Downloader' in scope`)

- [ ] **Paso 4: implementación**

`Packages/VMCore/Sources/VMCore/Creation/Downloader.swift`:

```swift
import CryptoKit
import Foundation

public struct DownloadRequest: Sendable {
    public var url: URL
    public var destination: URL
    /// SHA256 en hexadecimal si la fuente lo publica (Ubuntu sí, Apple no).
    public var expectedSHA256: String?

    public init(url: URL, destination: URL, expectedSHA256: String?) {
        self.url = url
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
    }
}

public enum DownloadError: Error, Equatable, LocalizedError {
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "El servidor respondió HTTP \(code)"
        case let .checksumMismatch(expected, actual): "SHA256 no coincide (esperado \(expected), obtenido \(actual))"
        }
    }
}

/// Descarga a `<destino>.part` con reanudación por `Range`, 3 intentos, validación de tamaño y SHA256.
/// Un fallo deja el `.part` para reanudar; cancelar lo borra.
public final class Downloader: Sendable {
    let session: URLSession
    let maxAttempts: Int
    let retryDelay: Duration

    public init(session: URLSession = .shared, maxAttempts: Int = 3, retryDelay: Duration = .seconds(2)) {
        self.session = session
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
    }

    public static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension("part")
    }

    public func download(_ request: DownloadRequest, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected = request.expectedSHA256?.lowercased()

        if fm.fileExists(atPath: request.destination.path) {
            if try expected == nil || Self.sha256(of: request.destination) == expected {
                progress(1)
                return request.destination
            }
            try fm.removeItem(at: request.destination)
        }

        let part = Self.partialURL(for: request.destination)
        do {
            var attempt = 1
            while true {
                do {
                    try await fetch(request.url, into: part, progress: progress)
                    break
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                    attempt += 1
                    try await Task.sleep(for: retryDelay)
                }
            }
        } catch is CancellationError {
            try? fm.removeItem(at: part)
            throw CancellationError()
        }

        if let expected {
            let actual = try Self.sha256(of: part)
            guard actual == expected else {
                try? fm.removeItem(at: part)
                throw DownloadError.checksumMismatch(expected: expected, actual: actual)
            }
        }
        try fm.moveItem(at: part, to: request.destination)
        progress(1)
        return request.destination
    }

    private func fetch(_ url: URL, into part: URL, progress: @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let existing = ((try fm.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0

        var urlRequest = URLRequest(url: url)
        if existing > 0 { urlRequest.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        var written: Int64
        switch status {
        case 206:
            written = existing
            try handle.seek(toOffset: UInt64(existing))
        case 200:
            written = 0
            try handle.truncate(atOffset: 0)
        case 416:
            return // el parcial ya está completo; lo valida el SHA256
        default:
            throw DownloadError.httpStatus(status)
        }

        let total = response.expectedContentLength > 0 ? written + response.expectedContentLength : -1
        let chunkSize = 1 << 20
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(written) / Double(total)) }
            }
        }
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        // Validación de tamaño: si el servidor anunció el total y llegó menos, es un corte; se reintenta reanudando.
        if total > 0, written < total { throw URLError(.networkConnectionLost) }
    }

    static func isRetryable(_ error: any Error) -> Bool {
        if let error = error as? DownloadError, case .httpStatus(let code) = error { return code >= 500 }
        return error is URLError
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Paso 5: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter DownloaderTests`
Expected: PASS (10 tests)

- [ ] **Paso 6: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): descargas reanudables con reintentos y SHA256"
```

---

### Tarea 1.6: `VMInstance` (ciclo de vida sobre `VZVirtualMachine`)

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Runtime/VMInstance.swift`

**Interfaces:**
- Consume: `VMBundle`, `VMConfig`, `VMStateMachine`, `VMConfigurationBuilder`.
- Produce (`@MainActor @Observable`): `VMInstance(bundle:config:)`, `id: UUID`, `bundle`, `config`, `machine: VZVirtualMachine?`, `state: VMState`, `lastError: String?`, `diskUsageBytes: UInt64`, `start() async throws`, `pause() async throws`, `resume() async throws`, `stop(force:timeout:) async throws`, `updateConfig(_:) throws`. Errores: `VMInstanceError` (`notRunning`, `stopTimedOut`). La Fase 3 añade snapshots aquí.

Esta tarea no tiene tests unitarios: instanciar `VZVirtualMachine` requiere el entitlement y un invitado real. La lógica de transiciones ya está cubierta por `VMStateMachineTests`; la verificación es manual en la Tarea 1.9.

- [ ] **Paso 1: implementación**

`Packages/VMCore/Sources/VMCore/Runtime/VMInstance.swift`:

```swift
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
    public func stop(force: Bool = false, timeout: Duration = .seconds(30)) async throws {
        guard let machine, state == .running || state == .paused else { return }
        try stateMachine.apply(.stopRequested)
        if machine.canRequestStop {
            try machine.requestStop()
            let deadline = ContinuousClock.now + timeout
            while state == .stopping, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard state == .stopping else { return }
        if force || !machine.canRequestStop {
            try await machine.stop()
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
        MainActor.assumeIsolated { didStop(error: nil) }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated { didStop(error: error) }
    }
}
```

- [ ] **Paso 2: compilar el paquete y correr todos los tests**

Run: `swift build --package-path Packages/VMCore && swift test --package-path Packages/VMCore`
Expected: `Build complete!` y todos los tests PASS.

- [ ] **Paso 3: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): VMInstance con inicio, pausa y apagado con timeout"
```

---

### Tarea 1.7: Creación de VMs Ubuntu y macOS

**Archivos:**
- Crear: `Packages/VMCore/Sources/VMCore/Creation/UbuntuRelease.swift`, `Packages/VMCore/Sources/VMCore/Creation/LinuxVMCreator.swift`, `Packages/VMCore/Sources/VMCore/Creation/MacOSVMCreator.swift`, `Packages/VMCore/Tests/VMCoreTests/UbuntuReleaseTests.swift`, `Packages/VMCore/Tests/VMCoreTests/LinuxVMCreatorTests.swift`

**Interfaces:**
- Consume: `Downloader`, `VMLibrary.create(_:populate:)`, `DiskSpace`, `VMConfigurationBuilder`.
- Produce: `CreationPhase` (`preparing`, `downloading(Double)`, `installing(Double)`, `finished`), `CreationError` (`checksumUnavailable`, `unsupportedRestoreImage`), `UbuntuRelease` (`version`, `isoFileName`, `isoURL`, `sha256SumsURL`, `parseSHA256(sums:fileName:)`), `LinuxVMCreator(library:downloader:cacheDir:session:requiredFreeBytes:)` con `create(config:localISO:onPhase:) async throws -> VMBundle`, `MacOSVMCreator(library:downloader:cacheDir:)` (`@MainActor`) con `create(config:localIPSW:onPhase:) async throws -> VMBundle`.

- [ ] **Paso 1: tests que fallan**

`Packages/VMCore/Tests/VMCoreTests/UbuntuReleaseTests.swift`:

```swift
import XCTest
@testable import VMCore

final class UbuntuReleaseTests: XCTestCase {
    func testURLsPointToLatestLTSDesktopArm64() {
        XCTAssertEqual(UbuntuRelease.isoFileName, "ubuntu-26.04.1-desktop-arm64.iso")
        XCTAssertEqual(UbuntuRelease.isoURL.absoluteString,
                       "https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso")
        XCTAssertEqual(UbuntuRelease.sha256SumsURL.absoluteString,
                       "https://cdimage.ubuntu.com/releases/26.04/release/SHA256SUMS")
    }

    func testParsesSHA256SUMS() {
        let sums = """
        c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57 *ubuntu-26.04-desktop-arm64.iso
        c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517 *ubuntu-26.04.1-desktop-arm64.iso
        """
        XCTAssertEqual(UbuntuRelease.parseSHA256(sums: sums, fileName: "ubuntu-26.04.1-desktop-arm64.iso"),
                       "c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517")
        XCTAssertNil(UbuntuRelease.parseSHA256(sums: sums, fileName: "otro.iso"))
    }
}
```

`Packages/VMCore/Tests/VMCoreTests/LinuxVMCreatorTests.swift`:

```swift
import CryptoKit
import XCTest
@testable import VMCore

final class LinuxVMCreatorTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var library: VMLibrary!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        library = VMLibrary(root: tmp.url.appending(path: "VMs", directoryHint: .isDirectory))
        StubURLProtocol.reset()
    }

    func makeCreator() -> LinuxVMCreator {
        let session = StubURLProtocol.session()
        return LinuxVMCreator(library: library, downloader: Downloader(session: session, retryDelay: .zero),
                              cacheDir: tmp.url.appending(path: "Cache", directoryHint: .isDirectory),
                              session: session, requiredFreeBytes: 0)
    }

    func testLocalISOIsAttachedAsInstallMedia() async throws {
        let iso = try tmp.file("mio.iso", contents: Data(count: 1024))
        let bundle = try await makeCreator().create(config: .defaults(for: .linux, name: "u"), localISO: iso) { _ in }
        XCTAssertEqual(try bundle.readConfig().installMediaPath, iso.path)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testDownloadsLatestISOWithPublishedChecksum() async throws {
        let isoBytes = Data("iso falso".utf8)
        let sha = SHA256.hash(data: isoBytes).map { String(format: "%02x", $0) }.joined()
        StubURLProtocol.handler = { request in
            if request.url == UbuntuRelease.sha256SumsURL {
                return .init(body: Data("\(sha) *\(UbuntuRelease.isoFileName)\n".utf8))
            }
            return .init(body: isoBytes)
        }
        let bundle = try await makeCreator().create(config: .defaults(for: .linux, name: "u"), localISO: nil) { _ in }
        let path = try XCTUnwrap(try bundle.readConfig().installMediaPath)
        XCTAssertTrue(path.hasSuffix("Cache/\(UbuntuRelease.isoFileName)"))
        XCTAssertEqual(try Data(contentsOf: URL(filePath: path)), isoBytes)
    }

    func testMissingChecksumFailsWithoutCreatingBundle() async throws {
        StubURLProtocol.handler = { _ in .init(body: Data("nada\n".utf8)) }
        do {
            _ = try await makeCreator().create(config: .defaults(for: .linux, name: "u"), localISO: nil) { _ in }
            XCTFail("debió lanzar")
        } catch CreationError.checksumUnavailable {}
        XCTAssertEqual(try library.list().entries.count, 0)
    }
}
```

- [ ] **Paso 2: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter "UbuntuReleaseTests|LinuxVMCreatorTests"`
Expected: FAIL de compilación (`cannot find 'UbuntuRelease' in scope`)

- [ ] **Paso 3: implementación**

`Packages/VMCore/Sources/VMCore/Creation/UbuntuRelease.swift`:

```swift
import Foundation

public enum CreationPhase: Equatable, Sendable {
    case preparing
    case downloading(Double)
    case installing(Double)
    case finished
}

public enum CreationError: Error, Equatable, LocalizedError {
    case checksumUnavailable
    case unsupportedRestoreImage

    public var errorDescription: String? {
        switch self {
        case .checksumUnavailable: "No se encontró el SHA256 publicado del ISO de Ubuntu."
        case .unsupportedRestoreImage: "Este Mac no soporta la imagen de restauración de macOS elegida."
        }
    }
}

/// Última LTS de Ubuntu para arm64 (actualizar `version` y `directory` cuando salga una nueva).
public enum UbuntuRelease {
    public static let version = "26.04.1"
    public static let directory = URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/")!
    public static var isoFileName: String { "ubuntu-\(version)-desktop-arm64.iso" }
    public static var isoURL: URL { directory.appending(path: isoFileName) }
    public static var sha256SumsURL: URL { directory.appending(path: "SHA256SUMS") }

    /// Formato de cada línea: `<hash> *<archivo>`.
    public static func parseSHA256(sums: String, fileName: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[1].hasPrefix("*") ? parts[1].dropFirst() : parts[1]
            if name == fileName { return String(parts[0]).lowercased() }
        }
        return nil
    }
}
```

`Packages/VMCore/Sources/VMCore/Creation/LinuxVMCreator.swift`:

```swift
import Foundation

public struct LinuxVMCreator: Sendable {
    public let library: VMLibrary
    public let downloader: Downloader
    public let cacheDir: URL
    public let session: URLSession
    public let requiredFreeBytes: UInt64

    public init(library: VMLibrary, downloader: Downloader, cacheDir: URL, session: URLSession = .shared,
                requiredFreeBytes: UInt64 = DiskSpace.requiredForCreate(.linux)) {
        self.library = library
        self.downloader = downloader
        self.cacheDir = cacheDir
        self.session = session
        self.requiredFreeBytes = requiredFreeBytes
    }

    /// Crea el paquete con el ISO conectado como USB; el usuario completa el instalador en la ventana de la VM.
    public func create(config: VMConfig, localISO: URL?, onPhase: @escaping @Sendable (CreationPhase) -> Void) async throws -> VMBundle {
        onPhase(.preparing)
        try library.ensureRoot()
        try DiskSpace.ensure(requiredFreeBytes, available: DiskSpace.available(at: library.root))
        _ = try VMName.validate(config.name)

        let iso: URL
        if let localISO {
            iso = localISO
        } else {
            let (data, _) = try await session.data(from: UbuntuRelease.sha256SumsURL)
            guard let sha = UbuntuRelease.parseSHA256(sums: String(decoding: data, as: UTF8.self), fileName: UbuntuRelease.isoFileName) else {
                throw CreationError.checksumUnavailable
            }
            let request = DownloadRequest(url: UbuntuRelease.isoURL, destination: cacheDir.appending(path: UbuntuRelease.isoFileName), expectedSHA256: sha)
            iso = try await downloader.download(request) { onPhase(.downloading($0)) }
        }

        var withMedia = config
        withMedia.installMediaPath = iso.path
        let bundle = try library.create(withMedia)
        onPhase(.finished)
        return bundle
    }
}
```

`Packages/VMCore/Sources/VMCore/Creation/MacOSVMCreator.swift`:

```swift
import Foundation
import Virtualization

@MainActor
public final class MacOSVMCreator {
    let library: VMLibrary
    let downloader: Downloader
    let cacheDir: URL

    public init(library: VMLibrary, downloader: Downloader, cacheDir: URL) {
        self.library = library
        self.downloader = downloader
        self.cacheDir = cacheDir
    }

    /// Descarga (o usa) un IPSW, crea plataforma + almacenamiento auxiliar e instala macOS.
    /// Si algo falla después de crear el paquete, el paquete se borra.
    public func create(config: VMConfig, localIPSW: URL?, onPhase: @escaping @MainActor @Sendable (CreationPhase) -> Void) async throws -> VMBundle {
        onPhase(.preparing)
        try library.ensureRoot()
        try DiskSpace.ensure(DiskSpace.requiredForCreate(.macOS), available: DiskSpace.available(at: library.root))
        _ = try VMName.validate(config.name)

        let ipsw: URL
        if let localIPSW {
            ipsw = localIPSW
        } else {
            let latest = try await VZMacOSRestoreImage.latestSupported
            let request = DownloadRequest(url: latest.url, destination: cacheDir.appending(path: latest.url.lastPathComponent), expectedSHA256: nil)
            ipsw = try await downloader.download(request) { fraction in
                Task { @MainActor in onPhase(.downloading(fraction)) }
            }
        }

        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw CreationError.unsupportedRestoreImage
        }
        var adjusted = config
        adjusted.cpuCount = max(adjusted.cpuCount, requirements.minimumSupportedCPUCount)
        adjusted.memoryBytes = max(adjusted.memoryBytes, requirements.minimumSupportedMemorySize)

        let bundle = try await library.create(adjusted) { bundle in
            try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdURL)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxURL, hardwareModel: requirements.hardwareModel, options: [])
            let vm = VZVirtualMachine(configuration: try VMConfigurationBuilder.build(config: adjusted, bundle: bundle))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onPhase(.installing(fraction)) }
            }
            defer { observation.invalidate() }
            try await installer.install()
        }
        onPhase(.finished)
        return bundle
    }
}
```

- [ ] **Paso 4: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter "UbuntuReleaseTests|LinuxVMCreatorTests"`
Expected: PASS (5 tests).

- [ ] **Paso 5: commit**

```bash
git add Packages/VMCore
git commit -m "feat(vmcore): crear VMs Ubuntu (ISO verificado) y macOS (IPSW + instalador)"
```

---

### Tarea 1.8: App — modelo, biblioteca y asistente "Nueva VM"

**Archivos:**
- Crear: `VMBox/Model/AppModel.swift`, `VMBox/Views/LibraryView.swift`, `VMBox/Views/NewVMSheet.swift`
- Modificar: `VMBox/VMBoxApp.swift` (reemplazo completo)

**Interfaces:**
- Consume: `VMLibrary`, `VMInstance`, `StartPolicy`, `LinuxVMCreator`, `MacOSVMCreator`, `Downloader`, `VMBoxPaths`.
- Produce (`AppModel`, `@MainActor @Observable`): `library`, `vms: [VMInstance]`, `brokenBundles: [URL]`, `alertMessage: String?`, `openVMWindow: ((UUID) -> Void)?`, `reload()`, `instance(for:) -> VMInstance?`, `start(_:) async throws` (lanza `AppError.macOSLimitReached`), `stop(_:force:) async throws`, `createVM(config:localFile:onPhase:) async throws`, `perform(_:) async`, `suggestedName(for:) -> String`, `static let libraryPathKey`. La Fase 2 añade vistas registradas, actividad de agente y control.

- [ ] **Paso 1: modelo de la app**

`VMBox/Model/AppModel.swift`:

```swift
import Foundation
import Observation
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

    init() {
        let root = UserDefaults.standard.string(forKey: Self.libraryPathKey)
            .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? VMLibrary.defaultRoot
        library = VMLibrary(root: root)
        reload()
    }

    /// Relee la biblioteca conservando las instancias existentes (y sus VMs en ejecución).
    func reload() {
        do {
            let listing = try library.list()
            let existing = Dictionary(uniqueKeysWithValues: vms.map { ($0.id, $0) })
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
```

- [ ] **Paso 2: escena principal**

`VMBox/VMBoxApp.swift` (reemplazo completo):

```swift
import SwiftUI
import VMCore

@main
struct VMBoxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("VMBox", id: "library") {
            LibraryView()
                .environment(model)
        }
        WindowGroup("VM", for: UUID.self) { $vmID in
            if let vmID {
                VMWindowView(vmID: vmID)
                    .environment(model)
            }
        }
    }
}
```

- [ ] **Paso 3: biblioteca**

`VMBox/Views/LibraryView.swift`:

```swift
import SwiftUI
import VMCore

struct VMRef: Identifiable { let id: UUID }

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var showingNewVM = false
    @State private var settingsTarget: VMRef?

    var body: some View {
        Table(model.vms, selection: $selection) {
            TableColumn("Nombre") { vm in Text(vm.config.name) }
            TableColumn("SO") { vm in Text(vm.config.os.displayName) }
            TableColumn("Estado") { vm in Text(vm.state.displayName) }
            TableColumn("Disco") { vm in
                Text(ByteCountFormatter.string(fromByteCount: Int64(vm.diskUsageBytes), countStyle: .file))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
            if let id = ids.first { openWindow(value: id) }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.brokenBundles.isEmpty {
                Text("Paquetes ilegibles: \(model.brokenBundles.map(\.lastPathComponent).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange).padding(6)
            }
        }
        .toolbar {
            Button("Nueva VM", systemImage: "plus") { showingNewVM = true }
            Button("Iniciar", systemImage: "play.fill") {
                guard let id = selection else { return }
                Task { await model.perform { try await model.start(id) } }
            }
            .disabled(selection == nil)
            Button("Detener", systemImage: "stop.fill") {
                guard let id = selection else { return }
                Task { await model.perform { try await model.stop(id, force: false) } }
            }
            .disabled(selection == nil)
            Button("Abrir ventana", systemImage: "macwindow") {
                if let id = selection { openWindow(value: id) }
            }
            .disabled(selection == nil)
            Button("Configuración", systemImage: "slider.horizontal.3") {
                if let id = selection { settingsTarget = VMRef(id: id) }
            }
            .disabled(selection == nil)
        }
        .sheet(isPresented: $showingNewVM) { NewVMSheet() }
        .sheet(item: $settingsTarget) { ref in VMSettingsSheet(vmID: ref.id) }
        .alert("VMBox", isPresented: Binding(get: { model.alertMessage != nil },
                                             set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onAppear { model.openVMWindow = { openWindow(value: $0) } }
        .frame(minWidth: 640, minHeight: 320)
    }
}
```

- [ ] **Paso 4: asistente "Nueva VM" (3 pasos + progreso)**

`VMBox/Views/NewVMSheet.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers
import VMCore

struct NewVMSheet: View {
    enum Step { case system, resources, name, progress }
    enum Source: Hashable { case latest, localFile }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.system
    @State private var os = GuestOS.linux
    @State private var source = Source.latest
    @State private var localFile: URL?
    @State private var showingImporter = false
    @State private var config = VMConfig.defaults(for: .linux, name: "")
    @State private var phase: CreationPhase?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    private let maxCPU = ProcessInfo.processInfo.processorCount
    private let maxMemoryGiB = Int(ProcessInfo.processInfo.physicalMemory / .gib) - 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .system: systemStep
            case .resources: resourcesStep
            case .name: nameStep
            case .progress: progressStep
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [mediaType]) { result in
            if case .success(let url) = result { localFile = url }
        }
    }

    private var mediaType: UTType {
        os == .macOS ? (UTType(filenameExtension: "ipsw") ?? .data) : (UTType(filenameExtension: "iso") ?? .data)
    }

    private var systemStep: some View {
        Group {
            Text("1. Sistema").font(.headline)
            Picker("Sistema", selection: $os) {
                ForEach(GuestOS.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Origen", selection: $source) {
                Text(os == .macOS ? "Última versión compatible" : "Última LTS (\(UbuntuRelease.version))").tag(Source.latest)
                Text(os == .macOS ? "IPSW propio…" : "ISO propio…").tag(Source.localFile)
            }
            .pickerStyle(.radioGroup)
            if source == .localFile {
                HStack {
                    Text(localFile?.lastPathComponent ?? "Ningún archivo").foregroundStyle(.secondary)
                    Button("Elegir…") { showingImporter = true }
                }
            }
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Siguiente") {
                    let name = model.suggestedName(for: os)
                    config = VMConfig.defaults(for: os, name: name)
                    step = .resources
                }
                .disabled(source == .localFile && localFile == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var resourcesStep: some View {
        Group {
            Text("2. Recursos").font(.headline)
            Stepper("CPU: \(config.cpuCount)", value: $config.cpuCount, in: 1...maxCPU)
            Stepper("Memoria: \(config.memoryBytes / .gib) GB",
                    value: Binding(get: { Int(config.memoryBytes / .gib) }, set: { config.memoryBytes = UInt64($0) * .gib }),
                    in: 2...max(2, maxMemoryGiB))
            Stepper("Disco: \(config.diskBytes / .gib) GB",
                    value: Binding(get: { Int(config.diskBytes / .gib) }, set: { config.diskBytes = UInt64($0) * .gib }),
                    in: 20...1000, step: 10)
            HStack {
                Button("Atrás") { step = .system }
                Spacer()
                Button("Siguiente") { step = .name }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var nameStep: some View {
        Group {
            Text("3. Nombre").font(.headline)
            TextField("Nombre", text: $config.name)
            HStack {
                Button("Atrás") { step = .resources }
                Spacer()
                Button("Crear") { create() }
                    .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var progressStep: some View {
        Group {
            Text("Creando «\(config.name)»").font(.headline)
            switch phase {
            case .preparing, nil: ProgressView("Preparando…")
            case .downloading(let f): ProgressView("Descargando…", value: f)
            case .installing(let f): ProgressView("Instalando macOS…", value: f)
            case .finished: Text("Lista.")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if errorMessage != nil {
                    Button("Cerrar") { dismiss() }
                } else {
                    Button("Cancelar") { task?.cancel() }
                }
            }
        }
    }

    private func create() {
        step = .progress
        let config = self.config
        let file = source == .localFile ? localFile : nil
        task = Task {
            do {
                try await model.createVM(config: config, localFile: file) { phase = $0 }
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Paso 5: compilar** (la ventana de VM y el diálogo de configuración llegan en la Tarea 1.9; para compilar ahora, crear stubs mínimos)

`VMBox/Views/VMWindowView.swift` (stub, se reemplaza en 1.9):

```swift
import SwiftUI

struct VMWindowView: View {
    let vmID: UUID
    var body: some View { Text("VM \(vmID)") }
}
```

`VMBox/Views/VMSettingsSheet.swift` (stub, se reemplaza en 1.9):

```swift
import SwiftUI

struct VMSettingsSheet: View {
    let vmID: UUID
    var body: some View { Text("Configuración de \(vmID)") }
}
```

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`

- [ ] **Paso 6: verificación manual**

Run: `open build/Build/Products/Debug/VMBox.app`
Expected: biblioteca vacía; "Nueva VM" → Ubuntu → "ISO propio…" con el ISO de la Fase 0 → recursos 4/4/40 → nombre "Ubuntu" → Crear. La VM aparece en la tabla con estado "Detenida" y disco ≈0 bytes. Repetir con el mismo nombre: alerta "Ya existe una VM llamada «Ubuntu»".

- [ ] **Paso 7: commit**

```bash
git add VMBox
git commit -m "feat(app): biblioteca de VMs y asistente Nueva VM"
```

---

### Tarea 1.9: App — ventana de VM, barra de controles y configuración por VM

**Archivos:**
- Crear: `VMBox/Views/VMDisplayView.swift`, `VMBox/Views/VMToolbar.swift`
- Modificar: `VMBox/Views/VMWindowView.swift` y `VMBox/Views/VMSettingsSheet.swift` (reemplazo completo de los stubs)

**Interfaces:**
- Consume: `AppModel.instance(for:)`, `AppModel.start/stop/perform`, `VMInstance.machine/state/lastError/updateConfig/pause/resume`.
- Produce: `VMDisplayView(machine:onViewReady:)` (`NSViewRepresentable` de `VZVirtualMachineView`; `onViewReady` lo usa la Fase 2 para registrar la vista), `VMToolbar(vm:)` (la Fase 2 añade interruptor de agente y banner; la Fase 3, snapshots).

- [ ] **Paso 1: vista de la VM**

`VMBox/Views/VMDisplayView.swift`:

```swift
import SwiftUI
import Virtualization

struct VMDisplayView: NSViewRepresentable {
    let machine: VZVirtualMachine?
    var onViewReady: (VZVirtualMachineView) -> Void = { _ in }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = machine
        onViewReady(view)
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
    }
}
```

- [ ] **Paso 2: barra de controles**

`VMBox/Views/VMToolbar.swift`:

```swift
import SwiftUI
import VMCore

struct VMToolbar: View {
    @Environment(AppModel.self) private var model
    let vm: VMInstance

    var body: some View {
        HStack(spacing: 12) {
            Button("Iniciar", systemImage: "play.fill") {
                Task { await model.perform { try await model.start(vm.id) } }
            }
            .disabled(vm.state == .running || vm.state == .starting || vm.state == .stopping)
            Button("Pausar", systemImage: "pause.fill") {
                Task { await model.perform { try await vm.pause() } }
            }
            .disabled(vm.state != .running)
            Menu {
                Button("Forzar apagado") { Task { await model.perform { try await model.stop(vm.id, force: true) } } }
            } label: {
                Label("Detener", systemImage: "stop.fill")
            } primaryAction: {
                Task { await model.perform { try await model.stop(vm.id, force: false) } }
            }
            .fixedSize()
            .disabled(vm.state != .running && vm.state != .paused)
            Spacer()
            Text(vm.state.displayName).foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
```

- [ ] **Paso 3: ventana**

`VMBox/Views/VMWindowView.swift` (reemplazo completo):

```swift
import SwiftUI
import VMCore

struct VMWindowView: View {
    @Environment(AppModel.self) private var model
    let vmID: UUID

    var body: some View {
        if let vm = model.instance(for: vmID) {
            VStack(spacing: 0) {
                VMToolbar(vm: vm)
                Divider()
                ZStack {
                    VMDisplayView(machine: vm.machine)
                    if vm.machine == nil {
                        VStack(spacing: 8) {
                            Text(vm.state == .error ? "Error" : "VM detenida").font(.title2)
                            if let error = vm.lastError { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 520)
            .navigationTitle(vm.config.name)
        } else {
            Text("La VM ya no existe.").padding()
        }
    }
}
```

- [ ] **Paso 4: configuración por VM (CPU, RAM, expulsar ISO)**

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

    var body: some View {
        if let vm = model.instance(for: vmID) {
            let editable = !vm.state.isActive
            Form {
                Section("Recursos") {
                    Stepper("CPU: \(cpu)", value: $cpu, in: 1...ProcessInfo.processInfo.processorCount)
                    Stepper("Memoria: \(memoryGiB) GB", value: $memoryGiB, in: 2...max(2, Int(ProcessInfo.processInfo.physicalMemory / .gib) - 2))
                }
                .disabled(!editable)
                if vm.config.os == .linux, let media = vm.config.installMediaPath {
                    Section("Medio de instalación") {
                        Text(URL(filePath: media).lastPathComponent).foregroundStyle(.secondary)
                        Toggle("Expulsar al guardar (tras terminar la instalación)", isOn: $ejectMedia)
                    }
                    .disabled(!editable)
                }
                if !editable {
                    Text("Detén la VM para cambiar su configuración.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        do {
                            try vm.updateConfig { config in
                                config.cpuCount = cpu
                                config.memoryBytes = UInt64(memoryGiB) * .gib
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
            }
        }
    }
}
```

- [ ] **Paso 5: compilar**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`

- [ ] **Paso 6: verificación manual (Ubuntu)**

Run: `open build/Build/Products/Debug/VMBox.app`
Expected:
1. Seleccionar "Ubuntu" → Iniciar: se abre su ventana, arranca GRUB y el instalador. Completar la instalación en la ventana.
2. Al terminar, ⏹ (apagado ordenado) → estado "Detenida". Configuración → "Expulsar al guardar" → Guardar.
3. ▶︎ de nuevo: arranca el Ubuntu instalado desde `disk.img`. ⏸ y ▶︎ pausan y reanudan.
4. "Abrir ventana" dos veces sobre la misma VM trae al frente la misma ventana (una por VM).
5. Con la VM corriendo, la columna "Disco" muestra el uso real tras "Iniciar"/"Detener" (se actualiza al reabrir la app).

- [ ] **Paso 7: commit**

```bash
git add VMBox
git commit -m "feat(app): ventana de VM con controles y configuración por VM"
```

---

### Tarea 1.10: Aceptación de la Fase 1 (macOS + límites)

**Archivos:**
- Modificar: `README.md` (sección "Uso básico")

**Interfaces:** ninguna nueva.

- [ ] **Paso 1: crear una VM macOS**

Run: `open build/Build/Products/Debug/VMBox.app` → Nueva VM → macOS → "Última versión compatible" → 4/8/80 → "macOS" → Crear.
Expected: progreso "Descargando…" (IPSW ≈18 GB, en `~/Library/Application Support/VMBox/Cache/`), luego "Instalando macOS…" hasta terminar; la VM aparece "Detenida". Iniciar: arranca el Asistente de configuración de macOS en la ventana (completarlo a mano).

- [ ] **Paso 2: cancelar una creación**

Expected: Nueva VM → Ubuntu → Última LTS → Crear → Cancelar durante "Descargando…": la hoja se cierra, no aparece VM nueva y no queda `ubuntu-26.04.1-desktop-arm64.iso.part` en la carpeta Cache (si el ISO ya estaba completo en Cache, la descarga se omite: probar renombrándolo antes).

- [ ] **Paso 3: límite de 2 macOS** (solo si hay espacio para una segunda y tercera VM macOS; si no, basta con `PoliciesTests`)

Expected: con dos VMs macOS corriendo, iniciar una tercera muestra la alerta del límite y no arranca.

- [ ] **Paso 4: README**

Añadir al final de `README.md`:

```markdown
## Uso básico
- **Nueva VM**: Ubuntu (última LTS o ISO propio) o macOS (último IPSW compatible o IPSW propio).
- Ubuntu: completa el instalador en la ventana de la VM; después, en Configuración, marca «Expulsar» el ISO.
- macOS: completa el Asistente de configuración la primera vez.
- Las VMs viven en `~/Library/Application Support/VMBox/VMs/<nombre>.vmbox/`; las descargas, en `…/VMBox/Cache/`.
```

- [ ] **Paso 5: commit**

```bash
git add README.md
git commit -m "docs: uso básico de la Fase 1"
```
