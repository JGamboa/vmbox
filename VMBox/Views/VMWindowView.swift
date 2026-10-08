import SwiftUI
import VMCore

struct VMWindowView: View {
    @Environment(AppModel.self) private var model
    let vmID: UUID

    var body: some View {
        if let vm = model.instance(for: vmID) {
            VStack(spacing: 0) {
                VMToolbar(vm: vm)
                Divider()
                ZStack {
                    VMDisplayView(machine: vm.machine) { model.register(view: $0, for: vm.id) }
                    if vm.machine == nil {
                        VStack(spacing: 8) {
                            Text(vm.state == .error ? "Error" : "VM detenida").font(.title2)
                            if let error = vm.lastError { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 520)
            .navigationTitle(vm.config.name)
            .modelAlert()
        } else {
            Text("La VM ya no existe.").padding()
        }
    }
}
