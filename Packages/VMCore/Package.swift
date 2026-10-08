// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
    ],
    targets: [
        .target(name: "VMCore"),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
    ]
)
