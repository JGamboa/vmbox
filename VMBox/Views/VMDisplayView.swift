import SwiftUI
import Virtualization

struct VMDisplayView: NSViewRepresentable {
    let machine: VZVirtualMachine?
    /// Linux sin aceleración 3D: resolución fija moderada (la imagen se escala) en vez de
    /// adoptar los píxeles Retina de la ventana, que el invitado dibuja por CPU.
    var reconfiguresDisplay = true
    var onViewReady: (VZVirtualMachineView) -> Void = { _ in }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = reconfiguresDisplay
        view.virtualMachine = machine
        onViewReady(view)
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.automaticallyReconfiguresDisplay != reconfiguresDisplay { view.automaticallyReconfiguresDisplay = reconfiguresDisplay }
        if view.virtualMachine !== machine { view.virtualMachine = machine }
    }
}
