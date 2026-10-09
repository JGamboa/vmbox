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

    private var guestToolsPath: String? {
        Bundle.main.url(forResource: "GuestTools", withExtension: nil)?.path
    }

    private func installCommand(for os: GuestOS) -> String {
        switch os {
        case .linux:
            "sudo mkdir -p /mnt/vmbox && sudo mount -t virtiofs vmbox /mnt/vmbox && sudo /mnt/vmbox/GuestTools/install-linux.sh"
        case .macOS:
            "sudo \"/Volumes/My Shared Files/GuestTools/install-macos.sh\""
        }
    }

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
                    if vm.config.agentControlEnabled, folders.contains(where: { !$0.readOnly }) {
                        Label("Con el control de agente activado, el agente puede modificar o borrar el contenido de las carpetas con escritura en tu Mac. Retirar el control corta y pausa la VM, pero no deshace lo ya escrito. Márcalas como solo lectura si no necesita escribir.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !folders.isEmpty {
                        Text(SharedFolderNaming.guestHint(for: vm.config.os))
                            .font(.caption).textSelection(.enabled)
                    }
                }
                .disabled(!editable)
                if let toolsPath = guestToolsPath {
                    Section("Guest agent (comandos, archivos, portapapeles)") {
                        Toggle("Compartir el instalador con la VM", isOn: Binding(
                            get: { folders.contains { $0.path == toolsPath } },
                            set: { share in
                                folders.removeAll { $0.path == toolsPath }
                                if share { folders.append(SharedFolder(path: toolsPath, readOnly: true)) }
                            }
                        ))
                        Text("Guarda, inicia la VM y ejecuta en su terminal:").font(.caption)
                        Text(installCommand(for: vm.config.os))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .disabled(!editable)
                }
                if !editable {
                    Text("Detén la VM para cambiar su configuración.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 520)
            .modelAlert()
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result, !folders.contains(where: { $0.path == url.path }) {
                    // Con el control de agente activado, las carpetas nuevas se comparten en solo lectura.
                    folders.append(SharedFolder(path: url.path, readOnly: vm.config.agentControlEnabled))
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
