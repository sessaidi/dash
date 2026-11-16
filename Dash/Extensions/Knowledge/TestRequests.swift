import Foundation

/// The routes tests call: Go `httptest.NewRequest` and `http.NewRequest(WithContext)`, supertest
/// `request(app).get(…)` and test clients (`client.get(…)`, `self.client.post(…)`, `testClient.get(…)`)
/// in test files. Each is a `tests_endpoint` ref from the test function with the route it calls;
/// `TestLinks` resolves it to a route the repository defines: `test —tests→ endpoint`.
struct TestRequestExtractor: CodeExtractor {
    let name = "tests"
    static let refKind = "tests_endpoint"
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    func accepts(path: String, language: String) -> Bool {
        ["go", "typescript", "javascript", "python"].contains(language) && SourceScan.isTest(path)
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        let patterns: [(regex: String, methodArgument: Int?)] = [
            (#"\b(?:httptest\.NewRequest|http\.NewRequest)\s*\("#, 0),
            (#"\bhttp\.NewRequestWithContext\s*\("#, 1),
            (#"\brequest\s*\(\s*[\w.]+\s*\)\s*\.(get|post|put|patch|delete)\s*\("#, nil),
            (#"\b\w*[cC]lient(?:\(\))?\.(get|post|put|patch|delete)\s*\("#, nil),
        ]
        for (pattern, methodArgument) in patterns where file.text.range(of: pattern, options: .regularExpression) != nil {
            for match in file.matches(SourceScan.regex(pattern)) {
                let open = match.range.location + match.range.length - 1
                guard let arguments = file.arguments(at: open) else { continue }
                let texts = arguments.ranges.map { file.string.substring(with: $0) }
                let method: String?
                let pathIndex: Int
                if let methodArgument {
                    guard texts.count > methodArgument + 1 else { continue }
                    method = Self.method(texts[methodArgument])
                    pathIndex = methodArgument + 1
                } else {
                    method = file.string.substring(with: match.range(at: 1)).uppercased()
                    pathIndex = 0
                }
                guard let method, texts.count > pathIndex, let path = route(texts[pathIndex], file: file) else { continue }
                let line = file.line(at: match.range.location)
                result.refs.append(KnowledgeRef(src: file.symbol(at: line) ?? file.fileID, kind: Self.refKind,
                                                names: [EndpointExtractor.id(method: method, path: EndpointExtractor.normalize(path))], line: line))
            }
        }
        return result
    }

    /// "GET", `http.MethodGet` → GET.
    static func method(_ expression: String) -> String? {
        let text = expression.trimmingCharacters(in: .whitespaces)
        if let literal = SourceScan.literal(text)?.uppercased(), methods.contains(literal) { return literal }
        if let match = SourceScan.matches(#"^http\.Method(\w+)$"#, in: text).first, methods.contains(match[1].uppercased()) { return match[1].uppercased() }
        return nil
    }

    /// The path a URL expression ends up as: known parts as they are, unknown ones `{}`, without
    /// the server's address before the first "/" or the query string.
    private func route(_ expression: String, file: ExtractionInput) -> String? {
        var value = ""
        for term in SourceScan.splitTopLevel(expression, separator: "+") {
            value += file.evaluate(term.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "{}"
        }
        if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...].drop { $0 != "/" }) }
        while value.hasPrefix("{}") { value.removeFirst(2) }
        value = String(value.prefix { $0 != "?" && $0 != "#" })
        return value.hasPrefix("/") ? value : nil
    }
}

/// Test requests to the routes the repository defines: the very route at 0.9; else what
/// `ServiceLinks.match` finds (one same-length match counts as the route, 0.9).
enum TestLinks {
    static func link(repo: String, refs: [KnowledgeRef], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        guard !refs.isEmpty else { return [] }
        let defined = Set(try await store.definitions(repo: repo, idPrefix: "endpoint:").map(\.id))
        guard !defined.isEmpty else { return [] }
        let routes = defined.sorted().compactMap(ServiceLinks.Route.init)
        var edges: [KnowledgeEdge] = []
        for ref in refs {
            guard let id = ref.names.first else { continue }
            if defined.contains(id) {
                edges.append(KnowledgeEdge(src: ref.src, dst: id, kind: "tests", weight: 0.9, source: ExtractionLinks.source))
                continue
            }
            guard let call = ServiceLinks.Route(id) else { continue }
            let found = ServiceLinks.match(call, routes: routes, services: [], exposedBy: [:])
            for target in found {
                let weight = found.count == 1 && target.weight >= 0.8 ? 0.9 : target.weight
                edges.append(KnowledgeEdge(src: ref.src, dst: target.id, kind: "tests", weight: weight, source: ExtractionLinks.source))
            }
        }
        return edges
    }
}
