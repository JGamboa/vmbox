import SwiftUI

/// Alerta compartida de `AppModel.alertMessage`. Se presenta solo en la ventana activa,
/// de modo que aparece una vez, en la ventana desde la que actuó el usuario.
struct ModelAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.alert("VMBox", isPresented: Binding(
            get: { model.alertMessage != nil && appearsActive },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

extension View {
    func modelAlert() -> some View { modifier(ModelAlert()) }
}
