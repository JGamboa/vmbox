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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if model.isAgentActive(vm.id, at: context.date) {
                        Text("🤖 Agente controlando")
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity)
                            .padding(4)
                            .background(.yellow.opacity(0.35))
                    }
                }
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
