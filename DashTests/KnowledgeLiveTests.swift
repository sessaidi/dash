import Foundation
import Testing
@testable import Dash

/// Opt-in: DASH_KNOWLEDGE_REPO=<path> indexes a real checkout into a throwaway graph and prints what it found.
@MainActor
@Suite("Knowledge live")
struct KnowledgeLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_KNOWLEDGE_REPO"] != nil))
    func indexesARealRepository() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DASH_KNOWLEDGE_REPO"])
        let store = try KnowledgeStore(url: nil)
        let started = Date()
        let report = try await KnowledgeExtension.index(path, store: store, history: true)
        let counts = try await store.counts()
        print("KNOWLEDGELIVE \(report) in \(Int(Date().timeIntervalSince(started)))s")
        print("KNOWLEDGELIVE counts \(counts.sorted { $0.key < $1.key })")
        let edgeKinds = try await store.edgeCounts()
        print("KNOWLEDGELIVE edges \(edgeKinds.sorted { $0.key < $1.key })")
    }
}
