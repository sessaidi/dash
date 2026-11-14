import Foundation
import Testing
@testable import Dash

@MainActor
@Suite("Knowledge repositories")
struct KnowledgeRepositoryTests {
    func checkout(_ path: String, in root: URL, origin: String? = nil) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.appending(path: ".git"), withIntermediateDirectories: true)
        if let origin {
            try "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(origin)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
                .write(to: url.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test func findsCheckoutsAndOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dash-find-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let api = try checkout("fubo/services-presentation-api", in: root, origin: "git@github.com:fubotv/services-presentation-api.git")
        _ = try checkout("fubo/services-user", in: root)
        _ = try checkout("perso/dash", in: root)
        // Too deep, and inside node_modules: skipped.
        _ = try checkout("a/b/c/deep-services", in: root)
        _ = try checkout("x/node_modules/services-lib", in: root)
        let found = KnowledgeExtension.findCheckouts(matching: "services", roots: [root])
        #expect(found.map(\.lastPathComponent) == ["services-presentation-api", "services-user"])
        #expect(KnowledgeExtension.findCheckouts(matching: "", roots: [root]).count == 3)
        #expect(KnowledgeExtension.originURL(api) == "git@github.com:fubotv/services-presentation-api.git")
    }

    @Test func toolsAreOffered() {
        let knowledge = KnowledgeExtension(defaults: UserDefaults(suiteName: "k-\(UUID())")!, url: nil)
        let names = knowledge.tools.map(\.name)
        #expect(names.contains("knowledge_find_repos") && names.contains("knowledge_add_repository") && names.contains("knowledge_remove_repository"))
        #expect(knowledge.tools.first { $0.name == "knowledge_add_repository" }?.requiresApproval == true)
        #expect(knowledge.tools.first { $0.name == "knowledge_find_repos" }?.requiresApproval == false)
    }
}
