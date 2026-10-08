import SwiftUI
import Virtualization

struct VMDisplayView: NSViewRepresentable {
    let machine: VZVirtualMachine?
    var onViewReady: (VZVirtualMachineView) -> Void = { _ in }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = machine
        onViewReady(view)
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
    }
}
