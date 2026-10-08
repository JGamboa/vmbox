import SwiftUI
import VMCore

struct VMRef: Identifiable { let id: UUID }

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var showingNewVM = false
    @State private var settingsTarget: VMRef?

    var body: some View {
        Table(model.vms, selection: $selection) {
            TableColumn("Nombre") { vm in Text(vm.config.name) }
            TableColumn("SO") { vm in Text(vm.config.os.displayName) }
            TableColumn("Estado") { vm in Text(vm.state.displayName) }
            TableColumn("Disco") { vm in
                Text(ByteCountFormatter.string(fromByteCount: Int64(vm.diskUsageBytes), countStyle: .file))
            }
        }
        .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
            if let id = ids.first { openWindow(value: id) }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.brokenBundles.isEmpty {
                Text("Paquetes ilegibles: \(model.brokenBundles.map(\.lastPathComponent).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange).padding(6)
            }
        }
        .toolbar {
            Button("Nueva VM", systemImage: "plus") { showingNewVM = true }
            Button("Iniciar", systemImage: "play.fill") {
                guard let id = selection else { return }
                Task { await model.perform { try await model.start(id) } }
            }
            .disabled(selection == nil)
            Button("Detener", systemImage: "stop.fill") {
                guard let id = selection else { return }
                Task { await model.perform { try await model.stop(id, force: false) } }
            }
            .disabled(selection == nil)
            Button("Abrir ventana", systemImage: "macwindow") {
                if let id = selection { openWindow(value: id) }
            }
            .disabled(selection == nil)
            Button("Configuración", systemImage: "slider.horizontal.3") {
                if let id = selection { settingsTarget = VMRef(id: id) }
            }
            .disabled(selection == nil)
        }
        .sheet(isPresented: $showingNewVM) { NewVMSheet() }
        .sheet(item: $settingsTarget) { ref in VMSettingsSheet(vmID: ref.id) }
        .alert("VMBox", isPresented: Binding(get: { model.alertMessage != nil },
                                             set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onAppear { model.openVMWindow = { openWindow(value: $0) } }
        .frame(minWidth: 640, minHeight: 320)
    }
}
