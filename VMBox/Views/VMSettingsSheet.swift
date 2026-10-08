import SwiftUI

struct VMSettingsSheet: View {
    let vmID: UUID
    var body: some View { Text("Configuración de \(vmID)") }
}
