import SwiftUI
import VMCore

struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vmID: UUID
    @State private var snapshots: [SnapshotInfo] = []
    @State private var newName = ""
    @State private var busy = false
    @State private var restoreTarget: SnapshotInfo?
    @State private var deleteTarget: SnapshotInfo?

    var body: some View {
        if let vm = model.instance(for: vmID) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Snapshots de «\(vm.config.name)»").font(.headline)
                List(snapshots) { snapshot in
                    HStack {
                        Image(systemName: snapshot.includesMemory ? "memorychip" : "internaldrive")
                            .help(snapshot.includesMemory ? "Incluye memoria" : "Solo disco")
                        Text(snapshot.name).bold()
                        Text(snapshot.createdAt, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restaurar") { restoreTarget = snapshot }
                        Button("Eliminar", role: .destructive) { deleteTarget = snapshot }
                    }
                }
                .frame(minHeight: 200)
                HStack {
                    TextField("Nombre del nuevo snapshot", text: $newName)
                    Button("Crear") { create(vm) }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                if busy { ProgressView().controlSize(.small) }
                HStack {
                    Spacer()
                    Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 560)
            .onAppear { reload(vm) }
            .confirmationDialog("¿Restaurar «\(restoreTarget?.name ?? "")»?", isPresented: Binding(
                get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
                Button("Detener la VM y restaurar", role: .destructive) {
                    guard let target = restoreTarget else { return }
                    run(vm) { try await vm.restoreSnapshot(named: target.name) }
                }
            } message: {
                Text("Se descarta el estado actual de la VM.")
            }
            .confirmationDialog("¿Eliminar «\(deleteTarget?.name ?? "")»?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button("Eliminar", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    run(vm) { try vm.snapshots.delete(target.name) }
                }
            }
            .modelAlert()
        }
    }

    private func reload(_ vm: VMInstance) {
        snapshots = (try? vm.snapshots.list()) ?? []
    }

    private func create(_ vm: VMInstance) {
        let name = newName
        run(vm) {
            _ = try await vm.createSnapshot(named: name)
            newName = ""
        }
    }

    private func run(_ vm: VMInstance, _ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            await model.perform(action)
            busy = false
            reload(vm)
        }
    }
}
