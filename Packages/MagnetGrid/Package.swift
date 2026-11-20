// swift-tools-version: 6.0
import PackageDescription

/// A magnetic dashboard grid for SwiftUI: cells snap to the nearest slot while dragged or resized,
/// the others are pushed out of the way, and gaps close upward (or stay, in free placement).
let package = Package(
    name: "MagnetGrid",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MagnetGrid", targets: ["MagnetGrid"]),
    ],
    targets: [
        .target(name: "MagnetGrid"),
        .testTarget(name: "MagnetGridTests", dependencies: ["MagnetGrid"]),
    ]
)
