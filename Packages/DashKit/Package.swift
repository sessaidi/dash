// swift-tools-version: 6.0
import PackageDescription

/// The Dash extension SDK: what integrations, features and plugins build on.
/// - DashKit: extension protocols, metadata, widgets, Claude tools and services, activity,
///   storage (Keychain, preferences), connections, and the plugin entry point.
/// - DashKitUI: shared SwiftUI components and the snap grid.
/// - DashKitTesting: test doubles (host, Claude, permissions, integration, HTTP stubs) for
///   plugin tests (`import DashKitTesting`).
///
/// One dynamic framework, built with library evolution, so compiled `.dashplugin`
/// bundles keep working with newer Dash builds and share the app's copy at runtime.
let package = Package(
    name: "DashKit",
    platforms: [.macOS(.v15)],
    products: [
        // DashKitTesting ships inside the same framework: plugin test targets link the one
        // dynamic DashKit, and the doubles are a few small classes.
        .library(name: "DashKit", type: .dynamic, targets: ["DashKit", "DashKitUI", "DashKitTesting"]),
    ],
    targets: [
        .target(name: "DashKitUI", swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .target(name: "DashKit", dependencies: ["DashKitUI"], swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .target(name: "DashKitTesting", dependencies: ["DashKit"], swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .testTarget(name: "DashKitUITests", dependencies: ["DashKitUI"]),
        .testTarget(name: "DashKitTests", dependencies: ["DashKit", "DashKitTesting"]),
    ]
)
