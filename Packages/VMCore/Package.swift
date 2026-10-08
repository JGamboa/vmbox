// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
        .library(name: "ControlProtocol", targets: ["ControlProtocol"]),
    ],
    targets: [
        .target(name: "VMCore"),
        .target(name: "ControlProtocol"),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
        .testTarget(name: "ControlProtocolTests", dependencies: ["ControlProtocol"]),
    ]
)
