// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwiftAgent", targets: ["SwiftAgent"])
    ],
    targets: [
        .target(
            name: "SwiftAgent",
            path: "Sources/SwiftAgent"
        )
    ]
)
