// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkspaceKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
    ],
    targets: [
        .target(name: "WorkspaceKit"),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
    ]
)
