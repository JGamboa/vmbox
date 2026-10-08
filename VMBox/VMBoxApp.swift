import SwiftUI
import VMCore

@main
struct VMBoxApp: App {
    var body: some Scene {
        Window("VMBox", id: "library") {
            Text("VMBox — biblioteca en \(VMBoxPaths.vms.path)")
                .padding()
        }
    }
}
