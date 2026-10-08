import SwiftUI
import VMCore

struct VMToolbar: View {
    @Environment(AppModel.self) private var model
    let vm: VMInstance
    @State private var showingSnapshots = false

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
            Button("Snapshots", systemImage: "camera") { showingSnapshots = true }
            Toggle("Permitir control de agente", isOn: Binding(
                get: { vm.config.agentControlEnabled },
                set: { model.setAgentControl(vm.id, $0) }
            ))
            .toggleStyle(.switch)
            .labelStyle(.titleAndIcon)
            .help("Permite que vmbox-mcp (p. ej. Claude Code) vea y controle esta VM")
            Spacer()
            Text(vm.state.displayName).foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .sheet(isPresented: $showingSnapshots) { SnapshotsSheet(vmID: vm.id) }
    }
}
