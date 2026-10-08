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

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { log("El invitado se detuvo") }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated { log("La VM se detuvo con error: \(error)") }
    }
}
