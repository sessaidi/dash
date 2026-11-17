import DashKit
import Foundation

/// `knowledge_endpoints` (routes by service, path or method, with handler, callers and tests) and
/// `knowledge_owners` (who owns a path by CODEOWNERS, or what an owner owns). Read the graph only.
extension KnowledgeExtension {
    private struct EndpointsInput: Decodable { let service: String?; let repository: String?; let path: String?; let method: String?; let limit: Int? }
    private struct OwnersInput: Decodable { let path: String?; let owner: String? }

    var operationsTools: [DashiiTool] {
        [
            DashiiTool(
                name: "knowledge_endpoints",
                description: "HTTP routes the indexed code defines, filtered by service, repository, path or method: each with its handler (file:line), the services exposing it, its repository, who calls it from any repository (count and a few callers) and how many tests request it. Paths use {} for parameters (\"GET /users/{}\"); a filter like /users/:id matches too.",
                properties: ["service": JSONSchema.string("A service id or name (knowledge_search kind service)."),
                             "repository": JSONSchema.string("A repository name, path or id."),
                             "path": JSONSchema.string("Part of the path, e.g. /invoices."),
                             "method": JSONSchema.string("GET, POST, PUT, PATCH, DELETE…"),
                             "limit": JSONSchema.integer("Max routes (default 30, max 60).")]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                return try await endpoints(try input.toolInput(EndpointsInput.self), store: store)
            },
            DashiiTool(
                name: "knowledge_owners",
                description: "Who owns code by CODEOWNERS (the nearest rule, as GitHub resolves it), with the people who changed it most as a complement; or, given an owner, what it owns. Give a path (\"repo/path\", a path inside an indexed repository, or a file/directory id) or an owner (@team, @user or email).",
                properties: ["path": JSONSchema.string("A file or folder: repo/path, an absolute path, or a file:/dir:/repo: id."),
                             "owner": JSONSchema.string("@team, @user or email.")]
            ) { [weak self] input in
                guard let self, let store else { return nil }
                let request = try input.toolInput(OwnersInput.self)
                if let owner = request.owner, !owner.isEmpty { return try await owned(by: owner, store: store) }
                guard let path = request.path, !path.isEmpty else { throw ToolError("Give a path or an owner.") }
                return try await owners(of: path, store: store)
            },
        ]
    }

    // MARK: Endpoints

    private func endpoints(_ request: EndpointsInput, store: KnowledgeStore) async throws -> JSONValue {
        var ids: [String]
        if let service = request.service, !service.isEmpty {
            let scope = try await serviceScope(service, store: store)
            ids = try await store.neighbors(scope.services.first?.id ?? "", kinds: ["exposes"], limit: 5000).filter { !$0.incoming }.map(\.node.id)
            if ids.isEmpty { ids = try await store.definitions(repo: scope.repo, idPrefix: "endpoint:").filter { scope.contains($0.path) }.map(\.id) }
        } else if let repository = request.repository, !repository.isEmpty {
            let scope = try await serviceScope(repository, store: store)
            ids = try await store.definitions(repo: scope.repo, idPrefix: "endpoint:").map(\.id)
        } else {
            ids = try await store.definedEndpoints()
        }
        let method = request.method?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let path = request.path.map { EndpointExtractor.normalize($0.trimmingCharacters(in: .whitespaces)).lowercased() } ?? ""
        let matching = Array(Set(ids)).filter { id in
            let route = id.dropFirst("endpoint:".count)
            let parts = route.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return false }
            return (method.isEmpty || parts[0] == method) && (path.isEmpty || parts[1].lowercased().contains(path))
        }.sorted { a, b in
            let (x, y) = (a.drop { $0 != " " }, b.drop { $0 != " " })
            return x == y ? a < b : x < y
        }
        let limit = min(max(request.limit ?? 30, 1), 60)
        var rows: [JSONValue] = []
        for id in matching.prefix(limit) {
            var row: [String: JSONValue] = ["endpoint": .string(String(id.dropFirst("endpoint:".count)))]
            let neighbors = try await store.neighbors(id, kinds: ["handled_by", "defined_in", "exposes", "calls_endpoint", "tests"], limit: 500)
            if let handler = neighbors.first(where: { !$0.incoming && $0.edge.kind == "handled_by" })?.node {
                row["handler"] = .string(handler.qualified)
                row["at"] = .string("\(handler.path):\(handler.line)")
                row["repository"] = .string(Self.repoName(handler.repo))
            } else if let file = neighbors.first(where: { !$0.incoming && $0.edge.kind == "defined_in" })?.node {
                row["at"] = .string(file.path)
                row["repository"] = .string(Self.repoName(file.repo))
            }
            let services = neighbors.filter { $0.incoming && $0.edge.kind == "exposes" }.map(\.node.name)
            if !services.isEmpty { row["services"] = .array(Array(Set(services)).sorted().map { .string($0) }) }
            let callers = neighbors.filter { $0.incoming && $0.edge.kind == "calls_endpoint" }
            if !callers.isEmpty {
                row["callers"] = .number(Double(callers.count))
                row["called_from"] = .array(callers.prefix(3).map { caller in
                    let node = caller.node
                    let name = node.kind == "symbol" ? node.qualified + " at " : ""
                    return .string(name + Self.repoName(node.repo) + "/" + node.path + (node.kind == "symbol" ? ":\(node.line)" : ""))
                })
            }
            let tests = neighbors.filter { $0.incoming && $0.edge.kind == "tests" }.count
            if tests > 0 { row["tests"] = .number(Double(tests)) }
            rows.append(.object(row))
        }
        var result: [String: JSONValue] = ["endpoints": .array(rows)]
        if matching.count > limit { result["total"] = .number(Double(matching.count)) }
        if matching.isEmpty { result["note"] = "No route matches. knowledge_search with kind endpoint finds routes by words." }
        return .object(result)
    }

    // MARK: Owners

    private func owners(of text: String, store: KnowledgeStore) async throws -> JSONValue {
        let (repo, path) = try await locate(text, store: store)
        let owners = try await store.codeOwners(repo: repo, path: path)
        var byOwner: [String: [String]] = [:]
        for owner in owners { byOwner[owner.owner, default: []].append(owner.target) }
        var result: [String: JSONValue] = ["repository": .string(Self.repoName(repo)), "path": .string(path.isEmpty ? "(repository)" : path)]
        result["owners"] = .array(byOwner.sorted { $0.key < $1.key }.map { owner, targets in
            var entry: [String: JSONValue] = ["owner": .string(String(owner.dropFirst("owner:".count)))]
            if targets != [path.isEmpty ? "(repository)" : path] { entry["owns"] = .array(Array(Set(targets)).sorted().prefix(10).map { .string($0) }) }
            return .object(entry)
        })
        if owners.isEmpty { result["note"] = "No CODEOWNERS rule covers it." }
        let experts = try await store.experts(repo: repo, path: path, limit: 5)
        if !experts.isEmpty {
            result["changed_most_by"] = .array(experts.map { ["name": .string($0.person.name), "commits": .number(Double($0.commits))] })
        }
        return .object(result)
    }

    private func owned(by text: String, store: KnowledgeStore) async throws -> JSONValue {
        let name = text.trimmingCharacters(in: .whitespaces)
        let id = OwnershipExtractor.id(name.hasPrefix("@") || name.contains("@") ? name : "@" + name)
        guard let owner = try await store.node(id) else {
            let known = try await store.nodes(kind: "owner", limit: 50).map(\.name)
            throw ToolError("No code owner “\(name)”." + (known.isEmpty ? " No CODEOWNERS file is indexed." : " Owners: \(known.joined(separator: ", "))."))
        }
        let neighbors = try await store.neighbors(id, kinds: ["owns", "about"], limit: 500)
        let owned = neighbors.filter { !$0.incoming && $0.edge.kind == "owns" }.map { neighbor in
            Self.repoName(neighbor.node.kind == "repo" ? neighbor.node.id : neighbor.node.repo) + (neighbor.node.path.isEmpty ? "" : "/" + neighbor.node.path)
        }.sorted()
        var result: [String: JSONValue] = ["owner": .string(owner.name), "owns": .array(owned.prefix(100).map { .string($0) })]
        if owned.count > 100 { result["owns_total"] = .number(Double(owned.count)) }
        if let person = neighbors.first(where: { !$0.incoming && $0.edge.kind == "about" && $0.node.kind == "person" })?.node {
            result["person"] = .string(person.name)
        }
        return .object(result)
    }

    /// A repository and a path in it from "repo/path", an absolute path, or a file/dir/repo id.
    private func locate(_ text: String, store: KnowledgeStore) async throws -> (repo: String, path: String) {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        if wanted.hasPrefix("file:") || wanted.hasPrefix("dir:") || wanted.hasPrefix("repo:") {
            guard let node = try await store.node(wanted) else { throw ToolError("No node \(wanted). Use knowledge_search.") }
            return node.kind == "repo" ? (node.id, "") : (node.repo, node.path)
        }
        let repos = try await store.nodes(kind: "repo", limit: 10_000)
        let absolute = (wanted as NSString).expandingTildeInPath
        if let repo = repos.filter({ absolute == String($0.id.dropFirst(5)) || absolute.hasPrefix(String($0.id.dropFirst(5)) + "/") })
            .max(by: { $0.id.count < $1.id.count }) {
            return (repo.id, String(absolute.dropFirst(repo.id.count - 5)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        let parts = wanted.split(separator: "/", maxSplits: 1).map(String.init)
        if let repo = repos.first(where: { $0.name.caseInsensitiveCompare(parts[0]) == .orderedSame }) {
            return (repo.id, parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")) : "")
        }
        if repos.count == 1 { return (repos[0].id, wanted.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
        throw ToolError("Say which repository: “repo/\(wanted)”. Indexed: \(repos.map(\.name).sorted().joined(separator: ", ")).")
    }
}
