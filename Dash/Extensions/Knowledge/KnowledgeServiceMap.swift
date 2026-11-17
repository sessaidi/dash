import DashKit
import Foundation
import SQLite3

/// `knowledge_service_map`: a service or a repository as the rest of the system sees it: the
/// routes and gRPC services it serves, what it calls and which service answers, who calls it from
/// any repository, the topics it publishes and consumes and who's on the other side, the tables it
/// touches, the environment, flags and config it reads, its workloads and CI jobs, owners, docs
/// and dependencies, with file:line evidence. Reads the graph only.
extension KnowledgeExtension {
    private struct ServiceMapInput: Decodable { let name: String }
    static let serviceMapLimit = 30

    var serviceMapTool: DashiiTool {
        DashiiTool(
            name: "knowledge_service_map",
            description: "A service or repository as the rest of the system sees it: the HTTP endpoints it exposes (handler, file:line) and the gRPC services it implements, what it calls (endpoints, hosts and gRPC services, from which function, and which service answers), who calls it from any repository, the message topics it publishes and consumes (with the code on the other side), the database tables it reads, writes, migrates or models, the environment variables, feature flags and config keys its code reads, how it runs (workloads: image, replicas, resources; the CI jobs deploying it), its CODEOWNERS owners, the repository's docs about it, the packages and repositories it depends on, and where it's defined. Links matched across repositories by path, host or name have a confidence below 1. Give a repository (name, path or owner/name) or a service (id or name from knowledge_search, kind service).",
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

        // gRPC services, topics and tables its code is linked to, by target.
        let links = try await store.outgoing(repo: scope.repo, kinds: ["implements", "calls_rpc", "publishes", "consumes", "reads_table", "writes_table", "migrates",
                                                                       "checks_flag", "reads_config"])
            .filter { scope.contains($0.path) }
        func grouped(_ kind: String) -> [String: (weight: Double, from: [String])] {
            var result: [String: (weight: Double, from: [String])] = [:]
            for link in links where link.kind == kind {
                let location = Self.location(link.qualified, link.path, link.line)
                result[link.dst, default: (0, [])].weight = max(result[link.dst]?.weight ?? 0, link.weight)
                if result[link.dst]?.from.contains(location) == false { result[link.dst]?.from.append(location) }
            }
            return result
        }
        func ranked(_ groups: [String: (weight: Double, from: [String])]) -> [(key: String, value: (weight: Double, from: [String]))] {
            groups.sorted { ($0.value.from.count, $1.key) > ($1.value.from.count, $0.key) }
        }

        let implemented = grouped("implements")
        if !implemented.isEmpty {
            var entries: [JSONValue] = []
            for (service, link) in ranked(implemented).prefix(limit) {
                var entry = Self.target(service, weight: link.weight, from: link.from)
                if let methods = try await store.node(service)?.signature.components(separatedBy: ": ").dropFirst().first { entry["methods"] = .string(methods) }
                entries.append(.object(entry))
            }
            result["implements"] = .array(entries)
            if implemented.count > limit { result["implements_total"] = .number(Double(implemented.count)) }
        }

        // Calls: what code in scope calls, grouped by target, with who answers.
        var calls: [String: (weight: Double, from: [String])] = [:]
        for call in try await store.outgoingCalls(repo: scope.repo) where scope.contains(call.path) {
            calls[call.dst, default: (0, [])].weight = max(calls[call.dst]?.weight ?? 0, call.weight)
            calls[call.dst]?.from.append(Self.location(call.qualified, call.path, call.line))
        }
        calls.merge(grouped("calls_rpc")) { first, _ in first }
        var callEntries: [JSONValue] = []
        for (target, call) in calls.sorted(by: { ($0.value.from.count, $1.key) > ($1.value.from.count, $0.key) }).prefix(limit) {
            var entry = Self.target(target, weight: call.weight, from: call.from)
            let answeredBy = try await answering(target, store: store)
            if !answeredBy.isEmpty { entry["answered_by"] = .array(answeredBy.map { .string($0) }) }
            callEntries.append(.object(entry))
        }
        result["calls"] = .array(callEntries)
        if calls.count > limit { result["calls_total"] = .number(Double(calls.count)) }

        // Called by: callers of its routes, of the hosts that stand for its services and of the
        // gRPC services it implements, anywhere.
        var targets = exposed.sorted(by: Self.byPath).map { ($0, "calls_endpoint") }
        for service in scope.services {
            targets += try await store.neighbors(service.id, kinds: ["about"], limit: 50).filter { $0.incoming && $0.node.kind == "host" }.map { ($0.node.id, "calls_host") }
        }
        targets += ranked(implemented).map { ($0.key, "calls_rpc") }
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

        // Topics: what it publishes and who consumes it; what it consumes and who publishes it.
        for (kind, key, other, otherKey) in [("publishes", "publishes", "consumes", "consumed_by"), ("consumes", "consumes", "publishes", "published_by")] {
            let topics = grouped(kind)
            guard !topics.isEmpty else { continue }
            var entries: [JSONValue] = []
            for (topic, link) in ranked(topics).prefix(limit) {
                var entry = Self.target(topic, weight: link.weight, from: link.from)
                let others = try await otherSide(of: topic, kind: other, scope: scope, store: store)
                if !others.isEmpty {
                    entry[otherKey] = .array(others.prefix(5).map { .string($0) })
                    if others.count > 5 { entry[otherKey + "_total"] = .number(Double(others.count)) }
                }
                entries.append(.object(entry))
            }
            result[key] = .array(entries)
            if topics.count > limit { result[key + "_total"] = .number(Double(topics.count)) }
        }

        // Tables: read, written, migrated or modelled by code in scope.
        var tables: [String: [String: [String]]] = [:]
        var tableWeights: [String: Double] = [:]
        for (kind, key) in [("reads_table", "reads"), ("writes_table", "writes"), ("migrates", "migrated_by")] {
            for (table, link) in grouped(kind) {
                tables[table, default: [:]][key] = link.from
                // How sure a read or write by name is of its table; a migration names it exactly.
                if kind != "migrates" { tableWeights[table] = max(tableWeights[table] ?? 0, link.weight) }
            }
        }
        for (table, path) in try await store.definitions(repo: scope.repo, idPrefix: "table:") where scope.contains(path) {
            tables[table, default: [:]]["model", default: []].append(path)
        }
        if !tables.isEmpty {
            var entries: [JSONValue] = []
            let order = tables.sorted { ($0.value.values.map(\.count).reduce(0, +), $1.key) > ($1.value.values.map(\.count).reduce(0, +), $0.key) }
            for (table, uses) in order.prefix(limit) {
                var entry: [String: JSONValue] = ["table": .string(String(table.dropFirst("table:".count)))]
                for (key, from) in uses {
                    entry[key] = .array(from.prefix(5).map { .string($0) })
                    if from.count > 5 { entry[key + "_total"] = .number(Double(from.count)) }
                }
                if let weight = tableWeights[table], weight < 1 { entry["confidence"] = .number((weight * 100).rounded() / 100) }
                entries.append(.object(entry))
            }
            result["tables"] = .array(entries)
            if tables.count > limit { result["tables_total"] = .number(Double(tables.count)) }
        }

        // Environment its code reads.
        let variables = Set(try await store.environmentReads(repo: scope.repo).filter { scope.contains($0.path) }.map(\.name)).sorted()
        result["env"] = .array(variables.prefix(limit).map { .string($0) })
        if variables.count > limit { result["env_total"] = .number(Double(variables.count)) }

        // Flags its code checks and config keys it reads.
        for (kind, key) in [("checks_flag", "flags"), ("reads_config", "config")] {
            let targets = grouped(kind)
            guard !targets.isEmpty else { continue }
            result[key] = .array(ranked(targets).prefix(limit).map { .object(Self.target($0.key, weight: $0.value.weight, from: $0.value.from)) })
            if targets.count > limit { result[key + "_total"] = .number(Double(targets.count)) }
        }

        try await addOperations(to: &result, scope: scope, store: store)
        return .object(result)
    }

    /// How the scope runs and who looks after it: workloads, CI jobs, CODEOWNERS owners, the
    /// repository's docs about it and what it depends on.
    private func addOperations(to result: inout [String: JSONValue], scope: ServiceScope, store: KnowledgeStore) async throws {
        let limit = Self.serviceMapLimit
        var workloads: [KnowledgeNode] = []
        for service in scope.services {
            workloads += try await store.neighbors(service.id, kinds: ["deploys"], limit: 50).filter { !$0.incoming && $0.node.kind == "workload" }.map(\.node)
        }
        if workloads.isEmpty {
            workloads = try await store.nodes(kind: "workload", repo: scope.repo, limit: 500).filter { $0.path.isEmpty || scope.contains($0.path) }
        }
        if !workloads.isEmpty {
            let unique = Dictionary(workloads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.name < $1.name }
            result["workloads"] = .array(unique.prefix(limit).map { workload in
                var entry: [String: JSONValue] = ["workload": .string(workload.signature.isEmpty ? workload.name : workload.signature)]
                if !workload.path.isEmpty { entry["defined_in"] = .string(workload.path) }
                return .object(entry)
            })
            if unique.count > limit { result["workloads_total"] = .number(Double(unique.count)) }
        }

        var jobs: [String: (node: KnowledgeNode, deploys: Bool)] = [:]
        for service in scope.services {
            for neighbor in try await store.neighbors(service.id, kinds: ["deploys", "about"], limit: 100) where neighbor.incoming && neighbor.node.kind == "ci_job" {
                jobs[neighbor.node.id] = (neighbor.node, (jobs[neighbor.node.id]?.deploys ?? false) || neighbor.edge.kind == "deploys")
            }
        }
        if !jobs.isEmpty {
            let sorted = jobs.values.sorted { ($0.deploys ? 0 : 1, $0.node.name) < ($1.deploys ? 0 : 1, $1.node.name) }
            result["ci"] = .array(sorted.prefix(limit).map { job in
                ["job": .string(job.node.name), "defined_in": .string(job.node.path), "deploys": .bool(job.deploys)]
            })
            if jobs.count > limit { result["ci_total"] = .number(Double(jobs.count)) }
        }

        var owners: [String: [String]] = [:]
        for folder in scope.folders {
            for owner in try await store.codeOwners(repo: scope.repo, path: folder) {
                owners[owner.owner, default: []].append(owner.target)
            }
        }
        if !owners.isEmpty {
            result["owners"] = .array(owners.sorted { $0.key < $1.key }.map { owner, targets in
                ["owner": .string(String(owner.dropFirst("owner:".count))), "owns": .array(Array(Set(targets)).sorted().prefix(5).map { .string($0) })]
            })
        }

        let docs = try await store.nodes(kind: "doc", repo: scope.repo, limit: 2000)
            .filter { scope.contains($0.path) || scope.folders.contains(($0.path as NSString).deletingLastPathComponent) }
            .sorted { ($0.path.components(separatedBy: "/").count, $0.path) < ($1.path.components(separatedBy: "/").count, $1.path) }
        if !docs.isEmpty {
            result["docs"] = .array(docs.prefix(limit).map { ["doc": .string($0.name), "path": .string($0.path)] })
            if docs.count > limit { result["docs_total"] = .number(Double(docs.count)) }
        }

        // Manifests inside the scope, and the ones above it (a monorepo's root go.mod).
        let dependencies = try await store.dependencies(repo: scope.repo).filter { dependency in
            scope.contains(dependency.folder) || dependency.folder.isEmpty || scope.folders.contains { $0.hasPrefix(dependency.folder + "/") }
        }
        if !dependencies.isEmpty {
            let packages = Dictionary(dependencies.map { ($0.package, $0.version) }, uniquingKeysWith: { a, b in a.isEmpty ? b : a }).sorted { $0.key < $1.key }
            var entries: [JSONValue] = packages.prefix(limit).map { package, version in
                var entry: [String: JSONValue] = ["package": .string(String(package.dropFirst("pkg:".count)))]
                if !version.isEmpty { entry["version"] = .string(version) }
                return .object(entry)
            }
            for repo in try await store.neighbors(scope.repo, kinds: ["depends_on"], limit: 50) where !repo.incoming && repo.node.kind == "repo" {
                entries.insert(["repository": .string(repo.node.name)], at: 0)
            }
            result["depends_on"] = .array(entries)
            if packages.count > limit { result["depends_on_total"] = .number(Double(packages.count)) }
        }
    }

    /// The code publishing (or consuming) a topic outside the scope, through the Pub/Sub
    /// subscriptions tied to it too: "function at repo/path:line".
    private func otherSide(of topic: String, kind: String, scope: ServiceScope, store: KnowledgeStore) async throws -> [String] {
        // A subscription consumes its topic: consumers of a topic are also its subscriptions'
        // consumers; publishers to a subscription are its topic's publishers.
        let related = try await store.neighbors(topic, kinds: ["consumes"], limit: 50)
            .filter { $0.node.kind == "topic" && $0.incoming == (kind == "consumes") }.map(\.node.id)
        var result: [String] = []
        for id in [topic] + related {
            for neighbor in try await store.neighbors(id, kinds: [kind], limit: 200) where neighbor.incoming && neighbor.node.kind != "topic" {
                let node = neighbor.node
                if node.repo == scope.repo && scope.contains(node.path) { continue }
                let location = Self.location(node.kind == "symbol" ? node.qualified : "", Self.repoName(node.repo) + "/" + node.path, node.kind == "symbol" ? node.line : 0)
                if !result.contains(location) { result.append(location) }
            }
        }
        return result.sorted()
    }

    /// Who serves a route (its services, else the repositories defining it), what a host stands
    /// for, or which repositories implement a gRPC service.
    private func answering(_ target: String, store: KnowledgeStore) async throws -> [String] {
        if target.hasPrefix("grpc:") {
            return Array(Set(try await store.neighbors(target, kinds: ["implements"], limit: 50).filter(\.incoming).map { Self.repoName($0.node.repo) })).sorted()
        }
        if target.hasPrefix("host:") {
            return try await store.neighbors(target, kinds: ["about"], limit: 10).filter { !$0.incoming && $0.node.kind == "service" }
                .map { "\($0.node.name) (\(Self.repoName($0.node.repo)))" }
        }
        let services = try await store.neighbors(target, kinds: ["exposes"], limit: 10).filter(\.incoming).map { "\($0.node.name) (\(Self.repoName($0.node.repo)))" }
        if !services.isEmpty { return services }
        return Array(Set(try await store.neighbors(target, kinds: ["defined_in"], limit: 10).filter { !$0.incoming }.map { Self.repoName($0.node.repo) })).sorted()
    }

    private static func target(_ id: String, weight: Double, from: [String]) -> [String: JSONValue] {
        let keys = ["host": "host", "grpc": "rpc_service", "topic": "topic", "table": "table", "flag": "flag", "config": "config"]
        let key = keys[String(id.prefix { $0 != ":" })] ?? "endpoint"
        var entry: [String: JSONValue] = [key: .string(String(id.drop { $0 != ":" }.dropFirst()))]
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
        try outgoing(repo: repo, kinds: ["calls_endpoint", "calls_host"]).map { ($0.dst, $0.weight, $0.path, $0.line, $0.qualified) }
    }

    /// Edges of `kinds` leaving a repository's symbols and files: the source's path, line and name.
    func outgoing(repo: String, kinds: [String]) throws -> [(dst: String, kind: String, weight: Double, path: String, line: Int, qualified: String)] {
        let list = kinds.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")
        let statement = try prepare("""
            SELECT e.dst, e.kind, e.weight, n.path, n.line, CASE n.kind WHEN 'symbol' THEN n.qualified ELSE '' END FROM nodes n
            JOIN edges e ON e.src = n.id AND e.kind IN (\(list))
            WHERE n.repo = ?1 AND n.kind IN ('symbol', 'file')
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo])
        var result: [(String, String, Double, String, Int, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), text(statement, 1), sqlite3_column_double(statement, 2), text(statement, 3),
                           Int(sqlite3_column_int64(statement, 4)), text(statement, 5)))
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

    /// CODEOWNERS owners of a path ("" is the repository) as GitHub resolves them: the nearest
    /// `owns` edge from the file or folder up to the repository. A folder whose files have
    /// different owners has none of its own: then every owner of something inside it.
    func codeOwners(repo: String, path: String) throws -> [(owner: String, target: String)] {
        let root = String(repo.dropFirst(5))
        var candidates: [String] = []
        if !path.isEmpty { candidates += ["file:" + root + "/" + path, "dir:" + root + "/" + path] }
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            candidates.append("dir:" + root + "/" + folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        candidates.append(repo)
        for candidate in candidates {
            let owners = try strings("SELECT src FROM edges WHERE dst = ?1 AND kind = 'owns' ORDER BY src", [candidate])
            if !owners.isEmpty { return owners.map { ($0, path.isEmpty ? "(repository)" : path) } }
        }
        return try pairs("""
            SELECT DISTINCT e.src, n.path FROM edges e JOIN nodes n ON n.id = e.dst
            WHERE e.kind = 'owns' AND n.repo = ?1 AND (?2 = '' OR substr(n.path, 1, length(?2) + 1) = ?2 || '/')
            ORDER BY e.src, n.path
            """, [repo, path]).map { ($0.src, $0.dst) }
    }

    /// Packages a repository's manifests depend on: the manifest's folder ("" for the root), the
    /// package and the version that repository declares.
    func dependencies(repo: String) throws -> [(folder: String, package: String, version: String)] {
        let statement = try prepare("""
            SELECT CASE WHEN s.kind = 'repo' THEN '' ELSE s.path END, e.dst,
                   COALESCE((SELECT r.names FROM refs r WHERE r.repo = ?1 AND r.src = e.dst AND r.kind = ?2 LIMIT 1), '')
            FROM edges e JOIN nodes s ON s.id = e.src
            WHERE e.kind = 'depends_on' AND e.dst >= 'pkg:' AND e.dst < 'pkg;' AND (s.id = ?1 OR s.repo = ?1)
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, [repo, DependencyExtractor.refKind])
        var result: [(String, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append((text(statement, 0), text(statement, 1), text(statement, 2))) }
        return result
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
