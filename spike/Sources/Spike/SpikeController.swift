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
