import AppKit
import SwiftUI
import VMCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.libraryPathKey) private var libraryPath = VMLibrary.defaultRoot.path
    @AppStorage(AppModel.pauseOnRevokeKey) private var pauseOnRevoke = true
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
            Section("Control de agente") {
                Toggle("Pausar la VM al retirar «Permitir control de agente»", isOn: $pauseOnRevoke)
                Text("Al retirar el control, las llamadas en curso se cortan y el guest-agent mata los procesos que lanzó. Pausar congela además cualquier otro efecto (p. ej. escrituras en carpetas compartidas) hasta que reanudes la VM.")
                    .font(.caption).foregroundStyle(.secondary)
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
