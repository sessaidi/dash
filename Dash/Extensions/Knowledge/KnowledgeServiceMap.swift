import DashKit
import Foundation
import SQLite3

/// `knowledge_service_map`: a service or a repository as the rest of the system sees it: the
/// routes it serves, what it calls and which service answers, who calls it from any repository,
/// the environment it reads, with file:line evidence. Reads the graph only.
extension KnowledgeExtension {
    private struct ServiceMapInput: Decodable { let name: String }
    static let serviceMapLimit = 30

    var serviceMapTool: DashiiTool {
        DashiiTool(
            name: "knowledge_service_map",
            description: "A service or repository as the rest of the system sees it: the HTTP endpoints it exposes (handler, file:line), what it calls (endpoints and hosts, from which function, and which service answers), who calls it from any repository, the environment variables it reads and where it's defined. Calls matched across repositories by path or host have a confidence below 1. Give a repository (name, path or owner/name) or a service (id or name from knowledge_search, kind service).",
            properties: ["name": JSONSchema.string("A repository, or a service id or name.")],
            required: ["name"]
        ) { [weak self] input in
            guard let self, let store else { return nil }
            return try await serviceMap(try input.toolInput(ServiceMapInput.self).name, store: store)
        }
    }

    /// What the map covers: a repository (every service, every folder) or one service and the
    /// folders it runs from.
    struct ServiceScope {
        var repo: String
        var services: [KnowledgeNode]
        /// Folders of the repository ("" is all of it).
        var folders: [String]
        var service: KnowledgeNode?

        func contains(_ path: String) -> Bool {
            folders.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    func serviceScope(_ text: String, store: KnowledgeStore) async throws -> ServiceScope {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        if wanted.hasPrefix("service:"), let service = try await store.node(wanted), service.kind == "service" {
            return try await scope(of: service, store: store)
        }
        let repos = try await store.nodes(kind: "repo", limit: 10_000)
        let path = (wanted as NSString).expandingTildeInPath
        if let repo = repos.first(where: { $0.id == wanted || $0.id == "repo:" + path })
            ?? repos.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame || (!$0.qualified.isEmpty && wanted.hasSuffix($0.qualified)) }) {
            return ServiceScope(repo: repo.id, services: try await store.nodes(kind: "service", repo: repo.id, limit: 1000), folders: [""])
        }
        let named = try await store.nodes(kind: "service", limit: 100_000).filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        if named.count == 1 { return try await scope(of: named[0], store: store) }
        if named.count > 1 { throw ToolError("Several services are called “\(wanted)”: \(named.map(\.id).joined(separator: ", ")). Give one id.") }
        throw ToolError("No repository or service “\(wanted)”. Use knowledge_search with kind service.")
    }

    private func scope(of service: KnowledgeNode, store: KnowledgeStore) async throws -> ServiceScope {
        var folders = try await store.neighbors(service.id, kinds: ["runs"]).filter { !$0.incoming }.map { $0.node.kind == "repo" ? "" : $0.node.path }
        if folders.isEmpty {
            folders = try await store.neighbors(service.id, kinds: ["defined_in"]).filter { !$0.incoming }.map { ($0.node.path as NSString).deletingLastPathComponent }
        }
        return ServiceScope(repo: service.repo, services: [service], folders: Array(Set(folders)).sorted(), service: service)
    }

    func serviceMap(_ text: String, store: KnowledgeStore) async throws -> JSONValue {
        let scope = try await serviceScope(text, store: store)
        let limit = Self.serviceMapLimit
        var result: [String: JSONValue] = [:]
        if let service = scope.service {
            result["service"] = .string(service.name)
            result["id"] = .string(service.id)
            result["repository"] = .string(Self.repoName(scope.repo))
            result["runs_from"] = .array(scope.folders.map { .string($0.isEmpty ? "(repository root)" : $0) })
            result["defined_in"] = .array(try await store.neighbors(service.id, kinds: ["defined_in"]).filter { !$0.incoming }.map { .string($0.node.path) })
        } else {
            result["repository"] = .string(Self.repoName(scope.repo))
            var services: [JSONValue] = []
            for service in scope.services.sorted(by: { $0.name < $1.name }) {
                services.append(["id": .string(service.id), "name": .string(service.name), "defined_in": .string(service.signature.replacingOccurrences(of: "Defined in ", with: ""))])
            }
            result["services"] = .array(services)
        }

        // Exposes: routes the service (or any code of the repository) serves.
        let definitions = Dictionary(grouping: try await store.definitions(repo: scope.repo, idPrefix: "endpoint:"), by: \.id).mapValues { $0.map(\.path) }
        var exposed = Set(definitions.keys)
        if let service = scope.service {
            exposed = Set(try await store.neighbors(service.id, kinds: ["exposes"], limit: 5000).filter { !$0.incoming }.map(\.node.id))
        }
        let lines = try await store.refLines(repo: scope.repo, idPrefix: "endpoint:")
        var exposes: [JSONValue] = []
        for endpoint in exposed.sorted(by: Self.byPath).prefix(limit) {
            var entry: [String: JSONValue] = ["endpoint": .string(String(endpoint.dropFirst("endpoint:".count)))]
            let handler = try await store.neighbors(endpoint, kinds: ["handled_by"], limit: 10).first { !$0.incoming && $0.node.repo == scope.repo }?.node
            if let handler { entry["handler"] = .string(handler.qualified) }
            if let line = lines[endpoint] {
                entry["at"] = .string(line.path + (line.line > 0 ? ":\(line.line)" : ""))
            } else if let handler {
                entry["at"] = .string("\(handler.path):\(handler.line)")
            } else if let path = definitions[endpoint]?.first {
                entry["at"] = .string(path)
            }
            exposes.append(.object(entry))
        }
        result["exposes"] = .array(exposes)
        if exposed.count > limit { result["exposes_total"] = .number(Double(exposed.count)) }

        // Calls: what code in scope calls, grouped by target, with who answers.
        var calls: [String: (weight: Double, from: [String])] = [:]
        for call in try await store.outgoingCalls(repo: scope.repo) where scope.contains(call.path) {
            calls[call.dst, default: (0, [])].weight = max(calls[call.dst]?.weight ?? 0, call.weight)
            calls[call.dst]?.from.append(Self.location(call.qualified, call.path, call.line))
        }
        var callEntries: [JSONValue] = []
        for (target, call) in calls.sorted(by: { ($0.value.from.count, $1.key) > ($1.value.from.count, $0.key) }).prefix(limit) {
            var entry = Self.target(target, weight: call.weight, from: call.from)
            let answeredBy = try await answering(target, store: store)
            if !answeredBy.isEmpty { entry["answered_by"] = .array(answeredBy.map { .string($0) }) }
            callEntries.append(.object(entry))
        }
        result["calls"] = .array(callEntries)
        if calls.count > limit { result["calls_total"] = .number(Double(calls.count)) }

        // Called by: callers of its routes and of the hosts that stand for its services, anywhere.
        var targets = exposed.sorted(by: Self.byPath).map { ($0, "calls_endpoint") }
        for service in scope.services {
            targets += try await store.neighbors(service.id, kinds: ["about"], limit: 50).filter { $0.incoming && $0.node.kind == "host" }.map { ($0.node.id, "calls_host") }
        }
        var calledBy: [JSONValue] = []
        var calledTotal = 0
        for (target, kind) in targets {
            let callers = try await store.neighbors(target, kinds: [kind], limit: 500).filter(\.incoming)
            guard !callers.isEmpty else { continue }
            calledTotal += 1
            guard calledBy.count < limit else { continue }
            let from = callers.map { Self.location($0.node.qualified, Self.repoName($0.node.repo) + "/" + $0.node.path, $0.node.line) }.sorted()
            calledBy.append(.object(Self.target(target, weight: callers.map(\.edge.weight).max() ?? 1, from: from)))
        }
        result["called_by"] = .array(calledBy)
        if calledTotal > limit { result["called_by_total"] = .number(Double(calledTotal)) }

        // Environment its code reads.
        let variables = Set(try await store.environmentReads(repo: scope.repo).filter { scope.contains($0.path) }.map(\.name)).sorted()
        result["env"] = .array(variables.prefix(limit).map { .string($0) })
        if variables.count > limit { result["env_total"] = .number(Double(variables.count)) }
        return .object(result)
    }

    /// Who serves a route (its services, else the repositories defining it) or what a host stands for.
    private func answering(_ target: String, store: KnowledgeStore) async throws -> [String] {
        if target.hasPrefix("host:") {
            return try await store.neighbors(target, kinds: ["about"], limit: 10).filter { !$0.incoming && $0.node.kind == "service" }
                .map { "\($0.node.name) (\(Self.repoName($0.node.repo)))" }
        }
        let services = try await store.neighbors(target, kinds: ["exposes"], limit: 10).filter(\.incoming).map { "\($0.node.name) (\(Self.repoName($0.node.repo)))" }
        if !services.isEmpty { return services }
        return Array(Set(try await store.neighbors(target, kinds: ["defined_in"], limit: 10).filter { !$0.incoming }.map { Self.repoName($0.node.repo) })).sorted()
    }

    private static func target(_ id: String, weight: Double, from: [String]) -> [String: JSONValue] {
        var entry: [String: JSONValue] = [id.hasPrefix("host:") ? "host" : "endpoint": .string(String(id.drop { $0 != ":" }.dropFirst()))]
        if weight < 1 { entry["confidence"] = .number((weight * 100).rounded() / 100) }
        entry["from"] = .array(from.prefix(5).map { .string($0) })
        if from.count > 5 { entry["callers"] = .number(Double(from.count)) }
        return entry
    }

    private static func location(_ qualified: String, _ path: String, _ line: Int) -> String {
        (qualified.isEmpty ? "" : qualified + " at ") + path + (line > 0 ? ":\(line)" : "")
    }

    static func repoName(_ repo: String) -> String { (String(repo.dropFirst(5)) as NSString).lastPathComponent }

    private static func byPath(_ a: String, _ b: String) -> Bool {
        let (x, y) = (a.drop { $0 != " " }, b.drop { $0 != " " })
        return x == y ? a < b : x < y
    }
}

extension KnowledgeStore {
    /// Calls (to endpoints and hosts) made by a repository's code: the caller's path, line and name.
    func outgoingCalls(repo: String) throws -> [(dst: String, weight: Double, path: String, line: Int, qualified: String)] {
        let statement = try prepare("""
            SELECT e.dst, e.weight, n.path, n.line, CASE n.kind WHEN 'symbol' THEN n.qualified ELSE '' END FROM nodes n
            JOIN edges e ON e.src = n.id AND e.kind IN ('calls_endpoint', 'calls_host')
            WHERE n.repo = ?1 AND n.kind IN ('symbol', 'file')
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        var result: [(String, Double, String, Int, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), sqlite3_column_double(statement, 1), text(statement, 2), Int(sqlite3_column_int64(statement, 3)), text(statement, 4)))
        }
        return result
    }

    /// Environment variables a repository's files read, with the file's path.
    func environmentReads(repo: String) throws -> [(name: String, path: String)] {
        try pairs("""
            SELECT substr(e.dst, 5), f.path FROM nodes f JOIN edges e ON e.src = f.id AND e.kind = 'reads_env'
            WHERE f.repo = ?1 AND f.kind = 'file'
            """, [repo]).map { ($0.src, $0.dst) }
    }

    /// Where refs from shared nodes (a route's handler, an operation's id) were written: file path and line.
    func refLines(repo: String, idPrefix: String) throws -> [String: (path: String, line: Int)] {
        let end = String(idPrefix.dropLast()) + String(UnicodeScalar(idPrefix.unicodeScalars.last!.value + 1)!)
        let statement = try prepare("""
            SELECT r.src, f.path, r.line FROM refs r JOIN nodes f ON f.id = r.file
            WHERE r.repo = ?1 AND r.src >= ?2 AND r.src < ?3
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo, idPrefix, end])
        var result: [String: (String, Int)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { result[text(statement, 0)] = (text(statement, 1), Int(sqlite3_column_int64(statement, 2))) }
        return result
    }
}
