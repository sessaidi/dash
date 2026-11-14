import Foundation

/// The entry point of a `.dashplugin` bundle.
///
/// A plugin is a macOS bundle compiled against DashKit. Its Info.plist names a subclass of
/// `DashPlugin` as `NSPrincipalClass`, plus `DashPluginID`, `DashPluginVersion` and
/// `DashKitMinimumVersion`. Dash loads approved plugins at launch (before the store opens, so
/// plugin SwiftData models work) and calls `makeExtensions()` once.
///
/// ```swift
/// final class AcmePlugin: DashPlugin {
///     override class func makeExtensions() -> [any DashExtension] { [AcmeIntegration(), AcmeDeploysFeature()] }
/// }
/// ```
@MainActor
open class DashPlugin: NSObject {
    /// Integrations and features this plugin provides.
    open class func makeExtensions() -> [any DashExtension] { [] }
}

/// What a plugin's C entry point returns. Dash resolves the entry with
/// `CFBundleGetFunctionPointerForName` because the Objective-C runtime can't look up
/// subclasses of DashKit's (resilient) `DashPlugin` by name.
///
/// Every plugin exports:
/// ```swift
/// @_cdecl("dash_plugin_entry")
/// public func dashPluginEntry() -> UnsafeMutableRawPointer {
///     DashPluginFactory.export { AcmePlugin.makeExtensions() }
/// }
/// ```
public final class DashPluginFactory: @unchecked Sendable {
    public static let entrySymbol = "dash_plugin_entry"

    public let make: @MainActor () -> [any DashExtension]

    public init(_ make: @escaping @MainActor () -> [any DashExtension]) {
        self.make = make
    }

    /// Retained pointer handed to Dash; Dash takes ownership.
    public static func export(_ make: @escaping @MainActor () -> [any DashExtension]) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(DashPluginFactory(make)).toOpaque()
    }
}

/// Info.plist keys of a `.dashplugin`.
public enum DashPluginKeys {
    public static let id = "DashPluginID"
    public static let version = "DashPluginVersion"
    public static let minimumDashKit = "DashKitMinimumVersion"
}
