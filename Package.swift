// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftAgentCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "SwiftAgentCore", targets: ["SwiftAgentCore"]),
        .executable(name: "MinimalAgentDemo", targets: ["MinimalAgentDemo"])
    ],
    targets: [
        .target(
            name: "SwiftAgentCore",
            path: "Sources/SwiftAgentCore"
        ),
        .executableTarget(
            name: "MinimalAgentDemo",
            dependencies: ["SwiftAgentCore"],
            path: "Examples/MinimalCLI"
        ),
        .testTarget(
            name: "SwiftAgentCoreTests",
            dependencies: ["SwiftAgentCore"],
            path: "Tests/SwiftAgentCoreTests"
        )
    ]
)
