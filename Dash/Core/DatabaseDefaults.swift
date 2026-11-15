import DashKit
import Foundation
import SwiftData

/// One preference: a key and its property-list value.
@Model
final class PreferenceRecord {
    @Attribute(.unique) var key: String
    var valueData: Data
    var updatedAt: Date

    init(key: String, valueData: Data) {
        self.key = key
        self.valueData = valueData
        updatedAt = .now
    }
}

/// UserDefaults kept in Dash's database instead of a plist: the app's and every plugin's settings
/// and state (`DashStorage.defaults`). Reads come from memory; writes are saved to the database a
/// moment later (and on quit). It has its own small store so plugins can read it while they are
/// constructed, before the main database (whose schema they extend) opens.
final class DatabaseDefaults: UserDefaults, @unchecked Sendable {
    private struct State {
        var values: [String: Any] = [:]
        var registered: [String: Any] = [:]
        var dirty: Set<String> = []
        var saveScheduled = false
    }

    private let lock = NSLock()
    private var current = State()
    private let container: ModelContainer
    /// Set once the plist values were copied in, so a key removed later doesn't come back.
    static let importedKey = "dash.preferences.imported"

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) throws {
        let configuration = url.map { ModelConfiguration("Preferences", url: $0) } ?? ModelConfiguration("Preferences", isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Schema([PreferenceRecord.self]), configurations: configuration)
        // A private suite nothing writes to: every accessor below is overridden.
        super.init(suiteName: "dev.sessaidi.Dash.database-defaults")!
        let context = ModelContext(container)
        var values: [String: Any] = [:]
        for record in (try? context.fetch(FetchDescriptor<PreferenceRecord>())) ?? [] {
            if let value = Self.decode(record.valueData) { values[record.key] = value }
        }
        withState { $0.values = values }
    }

    static var fileURL: URL { URL.applicationSupportDirectory.appending(path: "Dash/preferences.store") }

    /// Copies the app's plist preferences (Dash's and the plugins') into the database, once.
    func importOnce(from domain: [String: Any]) {
        guard object(forKey: Self.importedKey) == nil else { return }
        let stored = withState { Set($0.values.keys) }
        for (key, value) in domain where !Self.isSystemKey(key) && !stored.contains(key) {
            set(value, forKey: key)
        }
        set(true, forKey: Self.importedKey)
        flush()
    }

    /// AppKit's own entries (window frames, panels) stay in the plist.
    static func isSystemKey(_ key: String) -> Bool {
        key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("com.apple.") || key.hasPrefix("WebKit")
    }

    // MARK: Storage

    override func object(forKey defaultName: String) -> Any? {
        withState { $0.values[defaultName] ?? $0.registered[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard let value, !(value is NSNull) else { return removeObject(forKey: defaultName) }
        guard Self.encode(value) != nil else {
            DashLog.error("Preference \(defaultName) is not a property-list value; not saved.", category: "preferences")
            return
        }
        change(defaultName) { $0.values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        change(defaultName) { $0.values[defaultName] = nil }
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        withState { $0.registered.merge(registrationDictionary) { _, new in new } }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        withState { $0.registered.merging($0.values) { _, value in value } }
    }

    @discardableResult
    override func synchronize() -> Bool {
        flush()
        return true
    }

    /// Writes pending changes now.
    func flush() {
        let pending: [String: Any?] = withState { state in
            defer { state.dirty = []; state.saveScheduled = false }
            return Dictionary(uniqueKeysWithValues: state.dirty.map { ($0, state.values[$0]) })
        }
        guard !pending.isEmpty else { return }
        let context = ModelContext(container)
        for (key, value) in pending {
            let existing = try? context.fetch(FetchDescriptor<PreferenceRecord>(predicate: #Predicate { $0.key == key })).first
            if let value, let data = Self.encode(value) {
                if let existing {
                    existing.valueData = data
                    existing.updatedAt = .now
                } else {
                    context.insert(PreferenceRecord(key: key, valueData: data))
                }
            } else if let existing {
                context.delete(existing)
            }
        }
        do { try context.save() } catch { DashLog.error("Couldn't save preferences: \(error)", category: "preferences") }
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&current)
    }

    private func change(_ key: String, _ update: (inout State) -> Void) {
        willChangeValue(forKey: key)
        let schedule = withState { state in
            update(&state)
            state.dirty.insert(key)
            defer { state.saveScheduled = true }
            return !state.saveScheduled
        }
        didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
        if schedule {
            let box = UncheckedBox(self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { box.value.flush() }
        }
    }

    private static func encode(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: ["v": value], format: .binary, options: 0)
    }

    private static func decode(_ data: Data) -> Any? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["v"]
    }

    // MARK: Typed accessors (UserDefaults' conversions, on top of `object(forKey:)`)

    override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }

    override func integer(forKey defaultName: String) -> Int {
        switch object(forKey: defaultName) {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string) ?? Int(Double(string) ?? 0)
        default: 0
        }
    }

    override func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }

    override func double(forKey defaultName: String) -> Double {
        switch object(forKey: defaultName) {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string) ?? 0
        default: 0
        }
    }

    override func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let number as NSNumber: number.boolValue
        case let string as String: ["yes", "true", "1"].contains(string.lowercased())
        default: false
        }
    }

    override func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let string as String: string.hasPrefix("/") || string.hasPrefix("~") ? URL(filePath: (string as NSString).expandingTildeInPath) : URL(string: string)
        case let data as Data: (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data)) as URL?
        default: nil
        }
    }

    override func set(_ value: Int, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url?.absoluteString, forKey: defaultName) }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
