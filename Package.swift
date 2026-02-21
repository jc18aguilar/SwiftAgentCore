// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftAgentCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "SwiftAgentCore", targets: ["SwiftAgentCore"])
    ],
    targets: [
        .target(
            name: "SwiftAgentCore",
            path: "Sources/SwiftAgentCore"
        ),
        .testTarget(
            name: "SwiftAgentCoreTests",
            dependencies: ["SwiftAgentCore"],
            path: "Tests/SwiftAgentCoreTests"
        )
    ]
)
