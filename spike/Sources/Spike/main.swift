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
