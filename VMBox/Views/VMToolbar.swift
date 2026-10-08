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
