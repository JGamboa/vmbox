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
