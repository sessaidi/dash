// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeCodeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeCodeKit", targets: ["ClaudeCodeKit"]),
    ],
    targets: [
        .target(name: "ClaudeCodeKit"),
        .testTarget(
            name: "ClaudeCodeKitTests",
            dependencies: ["ClaudeCodeKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
