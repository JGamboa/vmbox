import SwiftUI
import VMCore

@main
struct VMBoxApp: App {
    @State private var model = AppModel()

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
    }
}
