// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Spike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Spike", path: "Sources/Spike")
    ]
)
