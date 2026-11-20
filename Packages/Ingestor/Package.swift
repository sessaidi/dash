// swift-tools-version: 6.0
import PackageDescription

/// Fetch, store, read: what an integration needs to bring a service's data into Dash's database
/// and let Dashii, agents and widgets read it there. Declare resources; Ingestor makes the
/// fetchers and readers, stores sanitized and capped answers in the synced store with their
/// freshness, pages through APIs, reuses ETags and backs off on rate limits. `IngestFeed` gives a
/// widget the stored copy at once and refreshes it in the background when it's stale.
///
/// Linked statically into each plugin (Dash.app provides DashKit, not Ingestor), so it can change
/// without DashKit's ABI rules; it only uses DashKit's public API.
let package = Package(
    name: "Ingestor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Ingestor", targets: ["Ingestor"]),
    ],
    dependencies: [
        .package(path: "../DashKit"),
    ],
    targets: [
        .target(name: "Ingestor", dependencies: [.product(name: "DashKit", package: "DashKit")]),
        .testTarget(name: "IngestorTests", dependencies: ["Ingestor", .product(name: "DashKit", package: "DashKit")]),
    ]
)
