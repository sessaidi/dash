import Darwin
import Foundation
import Testing
@testable import Dash

/// Indexing and analysing a large repository must not hold the whole repository in memory: the
/// peak footprint added by one run stays under a fixed budget. About 2.5 minutes, so only with
/// KG_MEMORY set (`TEST_RUNNER_KG_MEMORY=1 xcodebuild … test`).
@Suite(.serialized)
struct KnowledgeMemoryTests {
    /// For 2,000 files (52,000 symbols, 300,000 call names): holding every parsed file and every
    /// call edge, a run added 428 MB indexing and 525 MB with the analysis; streamed, 241 and 361.
    static let indexBudgetMB = 300.0
    static let budgetMB = 420.0

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KG_MEMORY"] != nil))
    func indexingALargeRepositoryStaysUnderTheMemoryBudget() async throws {
        let root = try Self.makeRepository(files: 2_000, functionsPerFile: 25, callsPerFunction: 6)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.deletingLastPathComponent().appending(path: root.lastPathComponent + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: storeURL.path + suffix) } }
        let store = try KnowledgeStore(url: storeURL)

        let sampler = FootprintSampler()
        sampler.start()
        var indexer = CodeIndexer(root: root, store: store)
        indexer.readHistory = false
        let report = try await indexer.index()
        let indexMB = sampler.peakSoFar()
        try await KnowledgeAnalysis.analyze(repo: indexer.repoID, root: root.path, store: store, vectors: true)
        let addedMB = sampler.stop()

        print("KnowledgeMemoryTests: \(report.parsed) files parsed, \(report.symbols) symbols, peak added \(Int(indexMB)) MB indexing, \(Int(addedMB)) MB overall")
        #expect(report.parsed == 2_000)
        #expect(indexMB < Self.indexBudgetMB, "indexing added \(Int(indexMB)) MB at peak")
        #expect(addedMB < Self.budgetMB, "indexing and analysis added \(Int(addedMB)) MB at peak")
    }

    /// Swift files whose functions call functions of other files by name, so call resolution,
    /// flows and vectors all have real work to do.
    static func makeRepository(files: Int, functionsPerFile: Int, callsPerFunction: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "dash-memory-\(UUID().uuidString)", directoryHint: .isDirectory)
        for file in 0..<files {
            let folder = root.appending(path: "Sources/Module\(file % 40)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var text = "import Foundation\n\nstruct Billing\(file) {\n"
            for function in 0..<functionsPerFile {
                text += "    func renew\(file)x\(function)(_ amount: Double) -> Double {\n"
                for call in 0..<callsPerFunction {
                    let target = (file * 7 + function * 3 + call * 11) % files
                    text += "        _ = Billing\(target)().renew\(target)x\((function + call) % functionsPerFile)(amount)\n"
                }
                text += "        return amount\n    }\n"
            }
            text += "}\n"
            try text.write(to: folder.appending(path: "Billing\(file).swift"), atomically: false, encoding: .utf8)
        }
        return root
    }
}

/// Samples this process's physical footprint every 10 ms and reports the highest value above
/// the starting footprint, in MB.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline = 0.0
    private var peak = 0.0
    private var running = false

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func start() {
        baseline = Self.footprintMB()
        peak = baseline
        running = true
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = Self.footprintMB()
                lock.withLock { peak = max(peak, now) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func peakSoFar() -> Double {
        lock.withLock { peak - baseline }
    }

    func stop() -> Double {
        let now = Self.footprintMB()
        return lock.withLock {
            running = false
            peak = max(peak, now)
            return peak - baseline
        }
    }
}
