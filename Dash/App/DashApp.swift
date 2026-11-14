import DashKit
import DashKitUI
import SwiftData
import SwiftUI

@main
struct DashApp: App {
    @NSApplicationDelegateAdaptor(DashAppDelegate.self) private var appDelegate
    @State private var host: ExtensionHost
    @State private var chat: ChatSession
    @State private var boot = BootState()

    init() {
        // `Dash --list-plugins`: load plugins, print what loaded, and exit (diagnostics).
        if CommandLine.arguments.contains("--list-plugins") {
            let result = PluginLoader.loadAll(reserved: Set(ExtensionHost.builtInExtensions().map(\.id)))
            for record in result.records {
                print("\(record.id) \(record.version) [\(record.bundled ? "bundled" : "user")] \(record.signature): \(record.state)")
            }
            print("extensions:", result.extensions.map { "\($0.id)(\($0.layer.rawValue))" }.joined(separator: ", "))
            exit(0)
        }
        // Under XCTest the app is only a test host: no real store, no polling of real accounts.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // Tests never touch the user's preferences.
        if testing { PreferenceStore.defaults = DashDefaults.shared }
        // Secrets: before any extension reads one. Tests use a throwaway file, never the real store.
        SecretStorage.apply()
        if testing {
            Keychain.backend = .file
            Keychain.fileURL = FileManager.default.temporaryDirectory.appending(path: "dash-test-secrets-\(UUID().uuidString).json")
        }
        let host: ExtensionHost
        do {
            // Plugins load before the store opens so their SwiftData models join the schema.
            let builtIn = ExtensionHost.builtInExtensions()
            let plugins = testing ? (records: [], extensions: []) : PluginLoader.loadAll(reserved: Set(builtIn.map(\.id)))
            host = try ExtensionHost(settings: AppSettings(), extensions: builtIn + plugins.extensions, inMemory: testing)
            host.plugins = plugins.records
        } catch {
            fatalError("Could not open the Dash database: \(error)")
        }
        _host = State(initialValue: host)
        _chat = State(initialValue: ChatSession(host: host))
        self.testing = testing
        if !testing, host.persona.hotKey { GlobalHotKey.shared.register() }
        if !testing { Notifier.shared.start(activity: host.activity, persona: host.persona) }
    }

    private let testing: Bool

    var body: some Scene {
        WindowGroup {
            Group {
                if boot.finished {
                    RootView()
                } else {
                    SplashView(state: boot)
                }
            }
                .frame(minWidth: 1180, minHeight: 720)
                .task {
                    // The boot runs once per launch (the task restarts if the window is recreated).
                    guard !testing, boot.steps.isEmpty else { return }
                    await host.boot(boot)
                }
                .environment(host)
                .environment(host.settings)
                .environment(chat)
                .modelContainer(host.container)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // The Debug menu only exists while debug mode is on (Settings › Debug).
            if host.settings.debugMode {
                CommandMenu("Debug") {
                    OpenDebugWindowButton()
                }
            }
        }

        Window("Debug", id: "debug") {
            DebugWindow()
                .environment(host)
                .environment(host.settings)
                .environment(chat)
                .modelContainer(host.container)
        }
        .defaultSize(width: 1000, height: 640)
        // Test runs host the tests in the app: no window (it would sit on the splash screen).
        .defaultLaunchBehavior(testing ? .suppressed : .automatic)

        MenuBarExtra(isInserted: .constant(!testing)) {
            DotMenu()
                .environment(host)
                .environment(chat)
        } label: {
            Image(systemName: "circle.circle.fill")
        }

        Settings {
            SettingsView()
                .environment(host)
                .environment(host.settings)
                .modelContainer(host.container)
        }
    }
}

private struct OpenDebugWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Debug Window") { openWindow(id: "debug") }
            .keyboardShortcut("d", modifiers: [.command, .option])
    }
}

/// The menu bar item: Dot is reachable even with the Dash window closed.
private struct DotMenu: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(ChatSession.self) private var chat
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var persona = host.persona
        Button("Ask \(persona.name)…  \(GlobalHotKey.description)") { summon() }
        Button("Open Dash") { DesktopMascot.shared.bringDashForward() }
        Divider()
        Toggle("Show \(persona.name) on the Desktop", isOn: Binding(
            get: { persona.mascotVisible && persona.place == .desktop },
            set: { show in
                persona.place = .desktop
                persona.mascotVisible = show
                DesktopMascot.shared.sync(host: host, chat: chat)
            }))
        Button("Settings…") { NSApp.activate(); openSettings() }
        Divider()
        Button("Quit Dash") { NSApp.terminate(nil) }
    }

    private func summon() {
        if !(persona.mascotVisible && persona.place == .desktop) {
            persona.place = .desktop
            persona.mascotVisible = true
            DesktopMascot.shared.sync(host: host, chat: chat)
        }
        NotificationCenter.default.post(name: .summonMascot, object: nil)
    }

    private var persona: Persona { host.persona }
}
