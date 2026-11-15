import Foundation

/// How a `.dashplugin` bundle hands Dash its extensions: one exported C function returning the
/// extensions to load. Dash loads approved plugins at launch, before the store opens (so plugin
/// SwiftData models join the schema), and calls it once.
///
/// ```swift
/// @_cdecl("dash_plugin_entry")
/// public func dashPluginEntry() -> UnsafeMutableRawPointer {
///     DashPluginFactory.export { [AcmeIntegration(), AcmeDeploysFeature()] }
/// }
/// ```
///
/// The Info.plist names the plugin with `DashPluginID`, `DashPluginVersion` and
/// `DashKitMinimumVersion` (see `DashPluginKeys`).
public final class DashPluginFactory: Sendable {
    public static let entrySymbol = "dash_plugin_entry"

    public let make: @MainActor @Sendable () -> [any DashExtension]

    public init(_ make: @escaping @MainActor @Sendable () -> [any DashExtension]) {
        self.make = make
    }

    /// The retained pointer the entry function returns; Dash takes ownership.
    public static func export(_ make: @escaping @MainActor @Sendable () -> [any DashExtension]) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(DashPluginFactory(make)).toOpaque()
    }
}

/// Info.plist keys of a `.dashplugin`.
public enum DashPluginKeys {
    public static let id = "DashPluginID"
    public static let version = "DashPluginVersion"
    public static let minimumDashKit = "DashKitMinimumVersion"
}
