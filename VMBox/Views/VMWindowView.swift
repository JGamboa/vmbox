import SwiftUI

struct VMWindowView: View {
    let vmID: UUID
    var body: some View { Text("VM \(vmID)") }
}
