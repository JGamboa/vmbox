import SwiftUI
import VMCore

@main
struct VMBoxApp: App {
    @State private var model = AppModel()

    /// El tamaño de ventana es el mismo para cualquier invitado (la resolución se calcula en puntos).
    private var vmWindowPlan: DisplayPlan { AppModel.displayPlan(for: .linux) }

    var body: some Scene {
        Window("VMBox", id: "library") {
            LibraryView()
                .environment(model)
        }
        WindowGroup("VM", for: UUID.self) { $vmID in
            if let vmID {
                VMWindowView(vmID: vmID)
                    .environment(model)
            }
        }
        .defaultSize(width: vmWindowPlan.windowWidth, height: vmWindowPlan.windowHeight + 40)
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
