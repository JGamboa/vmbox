// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
        .library(name: "ControlProtocol", targets: ["ControlProtocol"]),
        .library(name: "AgentControl", targets: ["AgentControl"]),
        .library(name: "MCPBridge", targets: ["MCPBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "VMCore"),
        .target(name: "ControlProtocol"),
        .target(name: "AgentControl", dependencies: ["VMCore", "ControlProtocol"]),
        .target(name: "MCPBridge", dependencies: ["ControlProtocol", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
        .testTarget(name: "ControlProtocolTests", dependencies: ["ControlProtocol"]),
        .testTarget(name: "AgentControlTests", dependencies: ["AgentControl"]),
        .testTarget(name: "MCPBridgeTests", dependencies: ["MCPBridge", .product(name: "MCP", package: "swift-sdk")]),
    ]
)
