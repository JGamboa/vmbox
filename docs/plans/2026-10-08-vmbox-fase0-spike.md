# VMBox — Fase 0: spike de captura y entrada

> **Para agentes:** SUB-SKILL REQUERIDO: usa superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar este plan tarea por tarea. Los pasos usan casillas (`- [ ]`). Lee primero el índice [2026-10-08-vmbox-mvp-00-indice.md](2026-10-08-vmbox-mvp-00-indice.md) (restricciones globales y foco de revisión) y la spec [docs/specs/2026-10-08-vmbox-design.md](../specs/2026-10-08-vmbox-design.md) §3.5 y §8.

**Objetivo:** confirmar en 1–2 días que, dentro del proceso de la app, se puede (a) capturar el contenido de una `VZVirtualMachineView` y (b) enviarle eventos sintéticos de teclado y mouse que lleguen al invitado, con una VM Ubuntu mínima (sesión live del ISO de escritorio, sin instalar).

**Arquitectura:** ejecutable SwiftPM desechable en `spike/` que crea una ventana AppKit con una `VZVirtualMachineView` y una barra de botones. Cada botón prueba una estrategia de captura o una ruta de entrada y guarda evidencia (PNG + log) en `/tmp/vmbox-spike/`. Los archivos `ViewCapture.swift` y `ViewInputInjector.swift` están escritos para que la Fase 2 copie la estrategia ganadora casi sin cambios.

**Stack:** Swift 6.3, AppKit, Virtualization.framework, CoreImage, ScreenCaptureKit (solo diagnóstico del plan B).

**Spec:** [docs/specs/2026-10-08-vmbox-design.md](../specs/2026-10-08-vmbox-design.md)

**Esta fase es una compuerta.** La Tarea 0.4 termina con un documento de resultados y **se detiene para revisión del usuario**. Si ninguna estrategia en proceso funciona, no se implementa el plan B: se consulta.

## Estructura de archivos

```
spike/
├── Package.swift                 ejecutable "Spike" (macOS 26)
├── Spike.entitlements            com.apple.security.virtualization
├── run.sh                        compila, firma ad hoc con el entitlement y ejecuta
└── Sources/Spike/
    ├── main.swift                arranque de NSApplication
    ├── SpikeVM.swift             VZVirtualMachineConfiguration mínima (EFI + ISO USB)
    ├── SpikeController.swift     ventana, botones y escenarios de prueba
    ├── ViewCapture.swift         estrategias de captura + estadísticas de imagen
    ├── ViewInputInjector.swift   rutas de entrada + síntesis de eventos
    └── SpikeKeys.swift           mapa mínimo de teclas US para el spike
scripts/fetch-ubuntu-iso.sh       descarga reanudable + verificación SHA256 del ISO
docs/spikes/2026-10-fase0-resultados.md
```

---

### Tarea 0.1: Arrancar Ubuntu live en una ventana propia

**Archivos:**
- Crear: `.gitignore`, `scripts/fetch-ubuntu-iso.sh`, `spike/Package.swift`, `spike/Spike.entitlements`, `spike/run.sh`, `spike/Sources/Spike/main.swift`, `spike/Sources/Spike/SpikeVM.swift`, `spike/Sources/Spike/SpikeController.swift`

**Interfaces:**
- Produce: `SpikeVM.make(isoPath: String) throws -> VZVirtualMachine` y `SpikeController` (delegado de la app, con `vmView: VZVirtualMachineView` y `window: NSWindow`) que las tareas 0.2 y 0.3 amplían.

- [ ] **Paso 1: `.gitignore` del repo**

```gitignore
.DS_Store
build/
.build/
.swiftpm/
*.xcodeproj/
xcuserdata/
guest-agent/dist/
```

- [ ] **Paso 2: script de descarga del ISO**

`scripts/fetch-ubuntu-iso.sh` (la app de la Fase 1 descarga a la misma carpeta y con el mismo nombre, así que este ISO se reutiliza):

```bash
#!/bin/bash
# Descarga (reanudable) el ISO de escritorio arm64 de la última LTS y verifica su SHA256.
set -euo pipefail
VER=26.04.1
BASE=https://cdimage.ubuntu.com/releases/26.04/release
FILE="ubuntu-$VER-desktop-arm64.iso"
DEST_DIR="$HOME/Library/Application Support/VMBox/Cache"
mkdir -p "$DEST_DIR"
cd "$DEST_DIR"
EXPECTED=$(curl -fsSL "$BASE/SHA256SUMS" | grep " \*$FILE\$" | cut -d' ' -f1)
if [ -f "$FILE" ] && [ "$(shasum -a 256 "$FILE" | cut -d' ' -f1)" = "$EXPECTED" ]; then
  echo "$DEST_DIR/$FILE"; exit 0
fi
curl -fL -C - -o "$FILE.part" "$BASE/$FILE"
ACTUAL=$(shasum -a 256 "$FILE.part" | cut -d' ' -f1)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "SHA256 no coincide (esperado $EXPECTED, obtenido $ACTUAL)" >&2
  rm -f "$FILE.part"; exit 1
fi
mv "$FILE.part" "$FILE"
echo "$DEST_DIR/$FILE"
```

Run: `chmod +x scripts/fetch-ubuntu-iso.sh && scripts/fetch-ubuntu-iso.sh` (≈4,2 GB; correr en segundo plano)
Expected: última línea `…/VMBox/Cache/ubuntu-26.04.1-desktop-arm64.iso`

- [ ] **Paso 3: paquete del spike**

`spike/Package.swift`:

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Spike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Spike", path: "Sources/Spike")
    ]
)
```

`spike/Spike.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
```

`spike/run.sh`:

```bash
#!/bin/bash
# Uso: spike/run.sh "/ruta/al/ubuntu-26.04.1-desktop-arm64.iso"
set -euo pipefail
cd "$(dirname "$0")"
ISO="${1:?uso: spike/run.sh /ruta/al/ubuntu.iso}"
swift build -c debug
codesign --force --sign - --entitlements Spike.entitlements .build/debug/Spike
mkdir -p /tmp/vmbox-spike
exec .build/debug/Spike "$ISO"
```

- [ ] **Paso 4: configuración mínima de la VM**

`spike/Sources/Spike/SpikeVM.swift`:

```swift
import Foundation
import Virtualization

@MainActor
enum SpikeVM {
    static let outputDir = URL(filePath: "/tmp/vmbox-spike", directoryHint: .isDirectory)

    /// VM Linux mínima: EFI, ISO como USB, red NAT, GPU virtio 1920×1200, teclado y puntero USB absolutos.
    static func make(isoPath: String) throws -> VZVirtualMachine {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 4
        config.memorySize = 4 << 30
        config.platform = VZGenericPlatformConfiguration()

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try VZEFIVariableStore(
            creatingVariableStoreAt: outputDir.appending(path: "nvram.bin"),
            options: [.allowOverwrite]
        )
        config.bootLoader = bootLoader

        let iso = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: isoPath), readOnly: true)
        config.storageDevices = [VZUSBMassStorageDeviceConfiguration(attachment: iso)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        config.graphicsDevices = [graphics]

        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        try config.validate()
        return VZVirtualMachine(configuration: config)
    }
}
```

- [ ] **Paso 5: ventana y arranque**

`spike/Sources/Spike/main.swift`:

```swift
import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("uso: Spike /ruta/al/ubuntu.iso\n".utf8))
    exit(2)
}
let app = NSApplication.shared
let controller = SpikeController(isoPath: CommandLine.arguments[1])
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
```

`spike/Sources/Spike/SpikeController.swift` (versión inicial; las tareas 0.2 y 0.3 añaden botones):

```swift
import AppKit
import Virtualization

@MainActor
final class SpikeController: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    let isoPath: String
    var window: NSWindow!
    var vmView: VZVirtualMachineView!
    var vm: VZVirtualMachine!
    let buttonBar = NSStackView()
    let statusLabel = NSTextField(labelWithString: "Arrancando…")

    init(isoPath: String) {
        self.isoPath = isoPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        vmView = VZVirtualMachineView()
        vmView.capturesSystemKeys = true
        vmView.automaticallyReconfiguresDisplay = true

        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        let root = NSStackView(views: [vmView, buttonBar, statusLabel])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        vmView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vmView.widthAnchor.constraint(equalTo: root.widthAnchor),
            vmView.heightAnchor.constraint(greaterThanOrEqualToConstant: 600),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "VMBox Spike"
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        setUpButtons()

        do {
            vm = try SpikeVM.make(isoPath: isoPath)
            vm.delegate = self
            vmView.virtualMachine = vm
            Task {
                do {
                    try await vm.start()
                    log("VM arrancada")
                } catch {
                    log("Error al arrancar: \(error)")
                }
            }
        } catch {
            log("Configuración inválida: \(error)")
        }
    }

    /// Las tareas 0.2 y 0.3 añaden botones aquí.
    func setUpButtons() {}

    func addButton(_ title: String, _ action: Selector) {
        buttonBar.addArrangedSubview(NSButton(title: title, target: self, action: action))
    }

    func log(_ message: String) {
        statusLabel.stringValue = message
        print("[spike] \(message)")
        let line = "\(Date()) \(message)\n"
        let url = SpikeVM.outputDir.appending(path: "log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { log("El invitado se detuvo") }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated { log("La VM se detuvo con error: \(error)") }
    }
}
```

- [ ] **Paso 6: compilar y arrancar**

Run: `chmod +x spike/run.sh && spike/run.sh "$HOME/Library/Application Support/VMBox/Cache/ubuntu-26.04.1-desktop-arm64.iso"`
Expected: se abre "VMBox Spike", aparece GRUB y luego el escritorio live de Ubuntu (o el asistente de instalación sobre el escritorio). El log dice `VM arrancada`. Si dice `Configuración inválida` con un error de entitlement, revisar que `codesign -d --entitlements - spike/.build/debug/Spike` muestre `com.apple.security.virtualization`.

- [ ] **Paso 7: commit**

```bash
git add .gitignore scripts/fetch-ubuntu-iso.sh spike
git commit -m "spike: arrancar Ubuntu live en una VZVirtualMachineView propia"
```

---

### Tarea 0.2: Estrategias de captura de la vista

**Archivos:**
- Crear: `spike/Sources/Spike/ViewCapture.swift`
- Modificar: `spike/Sources/Spike/SpikeController.swift` (`setUpButtons` + acciones de captura)

**Interfaces:**
- Consume: `SpikeController.vmView`, `SpikeController.log(_:)`, `SpikeController.addButton(_:_:)`.
- Produce: `ViewCapture.Strategy` (`cacheDisplay`, `layerRender`, `layerIOSurface`), `ViewCapture.capture(_ view: NSView, using: Strategy) -> CGImage?`, `ViewCapture.stats(_:) -> (mean: Double, stddev: Double)`, `ViewCapture.savePNG(_:to:)`, `ViewCapture.describeLayers(_:) -> String`, `ViewCapture.screenCaptureKit(window:) async throws -> CGImage` (plan B, solo diagnóstico), y en el controlador `bestCapture() -> CGImage?` que la Tarea 0.3 usa para la evidencia "después".

- [ ] **Paso 1: estrategias de captura**

`spike/Sources/Spike/ViewCapture.swift`:

```swift
import AppKit
import CoreImage
import ImageIO
import IOSurface
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum ViewCapture {
    /// Estrategias en proceso (plan A). Ninguna necesita permisos.
    enum Strategy: String, CaseIterable {
        case cacheDisplay    // NSView.cacheDisplay(in:to:)
        case layerRender     // CALayer.render(in:)
        case layerIOSurface  // IOSurface que la vista usa como contents de alguna capa
    }

    static func capture(_ view: NSView, using strategy: Strategy) -> CGImage? {
        switch strategy {
        case .cacheDisplay: cacheDisplay(view)
        case .layerRender: layerRender(view)
        case .layerIOSurface: layerIOSurface(view)
        }
    }

    static func cacheDisplay(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    static func layerRender(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    static func layerIOSurface(_ view: NSView) -> CGImage? {
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

    /// Diagnóstico: árbol de capas con clase, tamaño y tipo de `contents`.
    static func describeLayers(_ view: NSView) -> String {
        var lines: [String] = []
        func walk(_ layer: CALayer, depth: Int) {
            let contents = layer.contents.map { String(describing: type(of: $0)) } ?? "nil"
            lines.append("\(String(repeating: "  ", count: depth))\(type(of: layer)) frame=\(layer.frame) contents=\(contents)")
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth: depth + 1) }
        }
        lines.append("vista \(type(of: view)) subviews=\(view.subviews.map { String(describing: type(of: $0)) })")
        if let layer = view.layer { walk(layer, depth: 0) } else { lines.append("(sin capa)") }
        return lines.joined(separator: "\n")
    }

    /// Plan B (§3.5), SOLO diagnóstico: captura de la ventana propia con ScreenCaptureKit.
    /// Puede pedir permiso de Grabación de pantalla; anotar si lo pide.
    static func screenCaptureKit(window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ventana propia no encontrada en SCShareableContent"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Luminancia media y desviación estándar sobre una miniatura de 64×64.
    /// Una imagen negra o uniforme tiene stddev ≈ 0.
    static func stats(_ image: CGImage) -> (mean: Double, stddev: Double) {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Spike", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Spike", code: 3) }
    }
}
```

- [ ] **Paso 2: botones de captura**

En `SpikeController.swift`, reemplaza `func setUpButtons() {}` por:

```swift
    func setUpButtons() {
        addButton("Capturar (A)", #selector(captureAll))
        addButton("Capturar (plan B)", #selector(captureWithScreenCaptureKit))
    }

    @objc func captureAll() {
        var report: [String] = ["vista: \(vmView.bounds.size) puntos, backing \(window.backingScaleFactor)"]
        for strategy in ViewCapture.Strategy.allCases {
            guard let image = ViewCapture.capture(vmView, using: strategy) else {
                report.append("\(strategy.rawValue): nil")
                continue
            }
            let stats = ViewCapture.stats(image)
            let url = SpikeVM.outputDir.appending(path: "capture-\(strategy.rawValue).png")
            try? ViewCapture.savePNG(image, to: url)
            report.append(String(format: "%@: %dx%d mean=%.1f stddev=%.1f → %@",
                                 strategy.rawValue, image.width, image.height, stats.mean, stats.stddev, url.path))
        }
        try? ViewCapture.describeLayers(vmView).write(
            to: SpikeVM.outputDir.appending(path: "layers.txt"), atomically: true, encoding: .utf8)
        report.forEach(log)
    }

    @objc func captureWithScreenCaptureKit() {
        Task {
            do {
                let image = try await ViewCapture.screenCaptureKit(window: window)
                let stats = ViewCapture.stats(image)
                try ViewCapture.savePNG(image, to: SpikeVM.outputDir.appending(path: "capture-sck.png"))
                log(String(format: "screenCaptureKit: %dx%d mean=%.1f stddev=%.1f", image.width, image.height, stats.mean, stats.stddev))
            } catch {
                log("screenCaptureKit falló: \(error)")
            }
        }
    }

    /// Primera estrategia de plan A que devuelve una imagen no uniforme (stddev > 2).
    func bestCapture() -> CGImage? {
        for strategy in ViewCapture.Strategy.allCases {
            if let image = ViewCapture.capture(vmView, using: strategy), ViewCapture.stats(image).stddev > 2 {
                return image
            }
        }
        return nil
    }
```

- [ ] **Paso 3: probar la captura**

Run: `spike/run.sh "$HOME/Library/Application Support/VMBox/Cache/ubuntu-26.04.1-desktop-arm64.iso"`, esperar el escritorio de Ubuntu y pulsar **Capturar (A)**.
Expected: `/tmp/vmbox-spike/` contiene `capture-*.png`, `layers.txt` y `log.txt`. Abrir los PNG (`open /tmp/vmbox-spike/*.png`) y anotar para cada estrategia: ¿imagen nil, negra (stddev ≈ 0) o igual a lo que se ve en la ventana? Anotar también el tamaño en píxeles frente al de la vista (¿cubre exactamente la vista o es el framebuffer 1920×1200 con bandas?).

Repetir con: (1) la ventana parcialmente tapada por otra ventana; (2) otra app al frente; (3) la ventana redimensionada. Si **ninguna** estrategia A funciona, pulsar **Capturar (plan B)** y anotar si macOS pide permiso de Grabación de pantalla y si la imagen es correcta.

- [ ] **Paso 4: commit**

```bash
git add spike
git commit -m "spike: estrategias de captura de VZVirtualMachineView"
```

---

### Tarea 0.3: Rutas de entrada sintética (teclado, combinaciones, mouse, scroll)

**Archivos:**
- Crear: `spike/Sources/Spike/ViewInputInjector.swift`, `spike/Sources/Spike/SpikeKeys.swift`
- Modificar: `spike/Sources/Spike/SpikeController.swift`

**Interfaces:**
- Consume: `SpikeController.bestCapture()`, `ViewCapture.savePNG`, `SpikeController.log`.
- Produce: `InputRoute` (`directToView`, `windowSendEvent`, `appPostEvent`, `cgEventToPid` = plan B) y `ViewInputInjector` con `press(keyCode:characters:modifiers:)`, `type(_:)`, `click(at:right:count:)`, `drag(from:to:steps:)`, `scroll(at:dx:dy:)`. La Fase 2 reutiliza la síntesis de eventos y la ruta ganadora.

- [ ] **Paso 1: mapa mínimo de teclas**

`spike/Sources/Spike/SpikeKeys.swift`:

```swift
/// Subconjunto de key codes US-ANSI (kVK_*) suficiente para el spike.
enum SpikeKeys {
    static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, ".": 47, "/": 44, " ": 49, "\n": 36,
    ]
    static let control: UInt16 = 59
    static let option: UInt16 = 58
    static let shift: UInt16 = 56
    static let command: UInt16 = 55
}
```

- [ ] **Paso 2: inyector con rutas intercambiables**

`spike/Sources/Spike/ViewInputInjector.swift`:

```swift
import AppKit

enum InputRoute: String, CaseIterable {
    case directToView      // llamar keyDown/mouseDown/... de la vista
    case windowSendEvent   // NSWindow.sendEvent (despacho normal de la ventana)
    case appPostEvent      // NSApp.postEvent (cola de eventos del propio proceso)
    case cgEventToPid      // PLAN B (§3.5): CGEvent.postToPid(getpid()); solo diagnóstico
}

@MainActor
struct ViewInputInjector {
    let view: NSView
    let route: InputRoute
    var stepDelay: Duration = .milliseconds(30)

    // MARK: Entrega

    func deliver(_ event: NSEvent) {
        switch route {
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
        case .windowSendEvent:
            view.window?.sendEvent(event)
        case .appPostEvent:
            NSApp.postEvent(event, atStart: false)
        case .cgEventToPid:
            event.cgEvent?.postToPid(getpid())
        }
    }

    private func pause() async { try? await Task.sleep(for: stepDelay) }

    // MARK: Teclado

    private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    /// Presiona modificadores (flagsChanged), la tecla (keyDown/keyUp) y suelta modificadores en orden inverso.
    func press(keyCode: UInt16, characters: String, modifiers: [(code: UInt16, flag: NSEvent.ModifierFlags)]) async {
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            flags.insert(modifier.flag)
            deliver(keyEvent(.flagsChanged, keyCode: modifier.code, characters: "", flags: flags))
            await pause()
        }
        deliver(keyEvent(.keyDown, keyCode: keyCode, characters: characters, flags: flags))
        await pause()
        deliver(keyEvent(.keyUp, keyCode: keyCode, characters: characters, flags: flags))
        await pause()
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            deliver(keyEvent(.flagsChanged, keyCode: modifier.code, characters: "", flags: flags))
            await pause()
        }
    }

    func type(_ text: String) async {
        for character in text {
            guard let code = SpikeKeys.codes[character] else { continue }
            await press(keyCode: code, characters: character == "\n" ? "\r" : String(character), modifiers: [])
        }
    }

    // MARK: Mouse (puntos en coordenadas de la vista, origen abajo-izquierda)

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) -> NSEvent {
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        return NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: isUp ? 0 : 1
        )!
    }

    func click(at point: NSPoint, right: Bool = false, count: Int = 1) async {
        deliver(mouseEvent(.mouseMoved, at: point))
        await pause()
        for n in 1...count {
            deliver(mouseEvent(right ? .rightMouseDown : .leftMouseDown, at: point, clickCount: n))
            await pause()
            deliver(mouseEvent(right ? .rightMouseUp : .leftMouseUp, at: point, clickCount: n))
            await pause()
        }
    }

    func drag(from start: NSPoint, to end: NSPoint, steps: Int = 12) async {
        deliver(mouseEvent(.mouseMoved, at: start))
        await pause()
        deliver(mouseEvent(.leftMouseDown, at: start))
        await pause()
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            deliver(mouseEvent(.leftMouseDragged, at: p))
            await pause()
        }
        deliver(mouseEvent(.leftMouseUp, at: end))
        await pause()
    }

    func scroll(at point: NSPoint, dx: Int32, dy: Int32) async {
        deliver(mouseEvent(.mouseMoved, at: point))
        await pause()
        guard let window = view.window,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        // CGEvent usa coordenadas globales con origen arriba-izquierda de la pantalla principal.
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        if let event = NSEvent(cgEvent: cgEvent) { deliver(event) }
        await pause()
    }
}
```

- [ ] **Paso 3: escenarios en el controlador**

En `SpikeController.swift`, **reemplaza** el `setUpButtons()` de la Tarea 0.2 por la versión de abajo y añade el resto de miembros (antes de `guestDidStop`):

```swift
    let routePopup = NSPopUpButton()

    func setUpButtons() {
        addButton("Capturar (A)", #selector(captureAll))
        addButton("Capturar (plan B)", #selector(captureWithScreenCaptureKit))
        routePopup.addItems(withTitles: InputRoute.allCases.map(\.rawValue))
        buttonBar.addArrangedSubview(routePopup)
        addButton("Teclear", #selector(typeTest))
        addButton("Ctrl+Alt+T", #selector(comboTest))
        addButton("Super", #selector(superTest))
        addButton("Clic der.", #selector(rightClickTest))
        addButton("Doble clic", #selector(doubleClickTest))
        addButton("Arrastrar", #selector(dragTest))
        addButton("Scroll", #selector(scrollTest))
    }

    var injector: ViewInputInjector {
        ViewInputInjector(view: vmView, route: InputRoute(rawValue: routePopup.titleOfSelectedItem ?? "") ?? .windowSendEvent)
    }

    /// Espera 5 s (para poder poner otra app al frente y probar el caso en segundo plano),
    /// ejecuta la acción y guarda una captura "después".
    func scenario(_ name: String, _ action: @escaping @MainActor (ViewInputInjector) async -> Void) {
        let injector = self.injector
        log("\(name) [\(injector.route.rawValue)] en 5 s… (frontmost ahora: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        Task {
            try? await Task.sleep(for: .seconds(5))
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            await action(injector)
            try? await Task.sleep(for: .seconds(1))
            if let image = bestCapture() {
                let url = SpikeVM.outputDir.appending(path: "after-\(name)-\(injector.route.rawValue).png")
                try? ViewCapture.savePNG(image, to: url)
                log("\(name) [\(injector.route.rawValue)] hecho con \(front) al frente → \(url.lastPathComponent)")
            } else {
                log("\(name) [\(injector.route.rawValue)] hecho con \(front) al frente (sin captura A; revisar a ojo)")
            }
        }
    }

    var center: NSPoint { NSPoint(x: vmView.bounds.midX, y: vmView.bounds.midY) }

    @objc func typeTest() { scenario("teclear") { await $0.type("echo spike ok 123\n") } }

    @objc func comboTest() {
        scenario("ctrl-alt-t") {
            await $0.press(keyCode: SpikeKeys.codes["t"]!, characters: "t",
                           modifiers: [(SpikeKeys.control, .control), (SpikeKeys.option, .option)])
        }
    }

    /// Tecla modificadora sola (Super abre "Actividades" en GNOME).
    @objc func superTest() {
        scenario("super") { injector in
            injector.deliver(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command,
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: self.window.windowNumber, context: nil, characters: "",
                                              charactersIgnoringModifiers: "", isARepeat: false, keyCode: SpikeKeys.command)!)
            try? await Task.sleep(for: .milliseconds(50))
            injector.deliver(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: self.window.windowNumber, context: nil, characters: "",
                                              charactersIgnoringModifiers: "", isARepeat: false, keyCode: SpikeKeys.command)!)
        }
    }

    @objc func rightClickTest() { let c = center; scenario("clic-derecho") { await $0.click(at: c, right: true) } }

    @objc func doubleClickTest() {
        // Arriba a la izquierda, donde GNOME suele mostrar "Actividades"/íconos.
        let p = NSPoint(x: 60, y: vmView.bounds.height - 20)
        scenario("doble-clic") { await $0.click(at: p, count: 2) }
    }

    @objc func dragTest() {
        let b = vmView.bounds
        scenario("arrastrar") {
            await $0.drag(from: NSPoint(x: b.width * 0.3, y: b.height * 0.6), to: NSPoint(x: b.width * 0.6, y: b.height * 0.3))
        }
    }

    @objc func scrollTest() { let c = center; scenario("scroll") { await $0.scroll(at: c, dx: 0, dy: -400) } }
```

- [ ] **Paso 4: ejecutar la matriz de pruebas**

Run: `spike/run.sh "$HOME/Library/Application Support/VMBox/Cache/ubuntu-26.04.1-desktop-arm64.iso"` y esperar el escritorio live (cerrar el asistente de instalación si aparece).

Para cada ruta A (`directToView`, `windowSendEvent`, `appPostEvent`), en este orden:
1. **Ctrl+Alt+T** → Expected: se abre una Terminal en el invitado.
2. Clic real en la Terminal y **Teclear** → Expected: aparece `echo spike ok 123` y debajo `spike ok 123`.
3. **Super** → Expected: se abre/cierra la vista de Actividades.
4. **Clic der.** sobre el escritorio → Expected: menú contextual en la posición del centro de la vista.
5. **Arrastrar** sobre el escritorio → Expected: rectángulo de selección (o ventana movida).
6. **Scroll** sobre la Terminal con texto suficiente → Expected: el contenido se desplaza.
7. Repetir 1 y 2 **con otra app al frente** (pulsar el botón y en menos de 5 s hacer clic en Finder) → anotar si funciona sin que VMBox sea la app activa.

Anotar también si las modificadoras necesitan los eventos `flagsChanged` (probar una vez Ctrl+Alt+T quitando el bucle de `flagsChanged` y dejando solo `modifierFlags` en keyDown/keyUp) y si el clic cae donde se esperaba (la evidencia `after-*.png` lo muestra).

Solo si **ninguna** ruta A funciona: probar `cgEventToPid` (plan B) con los pasos 1 y 2 y anotar si macOS pide permiso (Accesibilidad / "control del equipo").

- [ ] **Paso 5: commit**

```bash
git add spike
git commit -m "spike: rutas de entrada sintética de teclado y mouse"
```

---

### Tarea 0.4: Resultados y compuerta de decisión

**Archivos:**
- Crear: `docs/spikes/2026-10-fase0-resultados.md`

**Interfaces:**
- Produce: las decisiones que consumen las Tareas 2.5 y 2.11 de la Fase 2: estrategia de captura ganadora, ruta de entrada ganadora, si las modificadoras necesitan `flagsChanged`, cómo se hace el scroll, y si la captura cubre exactamente la vista.

- [ ] **Paso 1: escribir los resultados con evidencia**

Usa esta estructura y rellena cada celda con lo observado (copiar las rutas de los PNG de `/tmp/vmbox-spike/` que respaldan cada fila a `docs/spikes/fase0/` si sirven de evidencia; no versionar el ISO ni la NVRAM):

```markdown
# Fase 0 — Resultados del spike (fecha)

## Captura
| Estrategia | Resultado (nil / negra / correcta) | Tamaño px vs vista | Tapada / otra app al frente / redimensionada |
|---|---|---|---|
| cacheDisplay | | | |
| layerRender | | | |
| layerIOSurface | | | |
| plan B: ScreenCaptureKit (solo si A falla) | | | ¿pidió permiso? |

Árbol de capas (extracto de layers.txt):

## Entrada
| Prueba | directToView | windowSendEvent | appPostEvent | con otra app al frente |
|---|---|---|---|---|
| Ctrl+Alt+T | | | | |
| Teclear | | | | |
| Super | | | | |
| Clic derecho | | | | |
| Doble clic | | | | |
| Arrastrar | | | | |
| Scroll | | | | |

¿Las modificadoras necesitan flagsChanged?:
¿El clic cae en el punto esperado?:

## Decisión
- Captura: <estrategia>
- Entrada: <ruta>
- Ajustes para la Fase 2 (letterbox, scroll, flagsChanged):
- ¿Hace falta plan B? sí/no — si sí, NO continuar: consultar al usuario.
```

- [ ] **Paso 2: commit**

```bash
git add docs/spikes
git commit -m "docs: resultados del spike de la Fase 0"
```

- [ ] **Paso 3: compuerta — detenerse y presentar al usuario**

Presentar el resumen de la decisión al usuario y **esperar su visto bueno** antes de la Fase 1. Si alguna capacidad (captura o entrada) solo funciona con el plan B, o solo funciona con VMBox al frente, describir las consecuencias (permisos TCC, la app debe estar activa) y pedir decisión. No escribir código del plan B sin esa aprobación.
