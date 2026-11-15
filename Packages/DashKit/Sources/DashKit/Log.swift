import Foundation
import os

/// App-wide logging: unified logging (Console.app, subsystem "dev.sessaidi.Dash") plus an
/// in-memory buffer the Debug window shows and exports. Never log secrets.
public enum DashLog {
    public enum Level: String, Sendable, CaseIterable, Comparable {
        case debug, info, notice, error, fault

        public static func < (a: Level, b: Level) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public struct Entry: Identifiable, Sendable, Hashable {
        public let id: Int
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    public static let subsystem = "dev.sessaidi.Dash"
    nonisolated(unsafe) private static var buffer: [Entry] = []
    nonisolated(unsafe) private static var nextID = 1
    nonisolated(unsafe) private static var debugEnabled = false
    private static let lock = NSLock()
    private static let capacity = 5000

    /// Debug mode: keep `.debug` entries too (they're dropped otherwise).
    public static var verbose: Bool {
        get { lock.withLock { debugEnabled } }
        set { lock.withLock { debugEnabled = newValue } }
    }

    public static var entries: [Entry] { lock.withLock { buffer } }

    public static func log(_ level: Level, _ message: String, category: String = "app") {
        if level == .debug, !verbose { return }
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
        lock.withLock {
            buffer.append(Entry(id: nextID, date: Date(), level: level, category: category, message: message))
            nextID += 1
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        }
    }

    public static func debug(_ message: String, category: String = "app") { log(.debug, message, category: category) }
    public static func info(_ message: String, category: String = "app") { log(.info, message, category: category) }
    public static func notice(_ message: String, category: String = "app") { log(.notice, message, category: category) }
    public static func error(_ message: String, category: String = "app") { log(.error, message, category: category) }

    @_spi(DashHost) public static func clear() { lock.withLock { buffer = [] } }
}
