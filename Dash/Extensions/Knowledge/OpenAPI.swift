import Foundation

/// Endpoints an OpenAPI 3 or Swagger 2 document (YAML or JSON) describes: one per operation
/// under `paths`, prefixed with `basePath` or the path of the document's only server. Each is
/// `defined_in` the document and refers to its `operationId` as the handler's name, resolved by
/// the link pass like a route's handler. The same endpoint declared in code is the same node.
struct OpenAPIExtractor: CodeExtractor {
    let name = "openapi"
    var sharedKinds: [String] { ["endpoint"] }

    struct Operation: Equatable {
        var method: String
        var path: String
        var line: Int
        var operationID: String?
    }

    func accepts(path: String, language: String) -> Bool {
        (language == "yaml" || language == "json") && !SourceScan.isTest(path)
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        guard let operations = file.language == "json" ? Self.json(file.text) : Self.yaml(file.text) else { return Extraction() }
        let routes = operations.map { operation in
            EndpointExtractor.Route(method: operation.method, path: operation.path, line: operation.line,
                                    handler: operation.operationID.map(Self.handlerNames) ?? [], framework: "openapi")
        }
        return EndpointExtractor.extraction(routes, in: file)
    }

    /// `getUser` also names a generated `GetUser`.
    static func handlerNames(_ operationID: String) -> [String] {
        let exported = operationID.prefix(1).uppercased() + operationID.dropFirst()
        return exported == operationID ? [operationID] : [operationID, exported]
    }

    /// The path part of a server URL: `https://{env}.acme.test/v1/` → "/v1".
    static func serverPath(_ url: String) -> String {
        var path = url
        if let scheme = path.range(of: "://") {
            let rest = path[scheme.upperBound...]
            path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
        }
        guard path.hasPrefix("/") else { return "" }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func prefix(basePath: String?, servers: [String]) -> String {
        if let basePath, basePath.hasPrefix("/") { return basePath == "/" ? "" : basePath }
        return servers.count == 1 ? serverPath(servers[0]) : ""
    }

    // MARK: YAML

    /// Reads `paths`, `basePath` and `servers` by indentation: enough of YAML for these documents.
    static func yaml(_ text: String) -> [Operation]? {
        guard text.range(of: #"(?m)^["']?(?:openapi|swagger)["']?\s*:"#, options: .regularExpression) != nil,
              text.range(of: #"(?m)^paths\s*:"#, options: .regularExpression) != nil else { return nil }
        var basePath: String?
        var servers: [String] = []
        var operations: [Operation] = []
        var section = ""
        var pathIndent: Int?, methodIndent: Int?
        var path: String?
        var open: Int?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = raw.prefix { $0 == " " }.count
            let entry = keyValue(trimmed)
            if indent == 0 {
                section = entry?.key ?? ""
                if section == "basePath" { basePath = entry?.value }
                pathIndent = nil; methodIndent = nil; path = nil; open = nil
                continue
            }
            if section == "servers" {
                if let url = SourceScan.matches(#"^-?\s*url\s*:\s*(\S+)"#, in: trimmed).first?[1] { servers.append(unquote(url)) }
                continue
            }
            guard section == "paths", let key = entry?.key, let value = entry?.value else { continue }
            if pathIndent == nil { pathIndent = indent }
            guard let paths = pathIndent, indent >= paths else { continue }
            if indent == paths {
                path = key.hasPrefix("/") ? key : nil
                methodIndent = nil; open = nil
                continue
            }
            guard let current = path else { continue }
            if methodIndent == nil { methodIndent = indent }
            guard let methods = methodIndent else { continue }
            if indent == methods {
                open = nil
                if EndpointExtractor.methods.contains(key.uppercased()) {
                    operations.append(Operation(method: key.uppercased(), path: current, line: index + 1))
                    open = operations.count - 1
                }
            } else if indent > methods, key == "operationId", let operation = open, operations[operation].operationID == nil, !value.isEmpty {
                operations[operation].operationID = value
            }
        }
        let prefix = prefix(basePath: basePath, servers: servers)
        return operations.map { var operation = $0; operation.path = EndpointExtractor.join(prefix, operation.path); return operation }
    }

    /// `key: value` (either may be quoted; the key may contain colons, as in `/v1/{name}:cancel`).
    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard !line.hasPrefix("-"), let match = SourceScan.matches(#"^((?:"[^"]*"|'[^']*'|\S.*?))\s*:(?:\s+(.*))?$"#, in: line).first else { return nil }
        var value = match.count > 2 ? match[2] : ""
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        return (unquote(match[1]), unquote(value.trimmingCharacters(in: .whitespaces)))
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        return String(text.dropFirst().dropLast())
    }

    // MARK: JSON

    static func json(_ text: String) -> [Operation]? {
        guard text.range(of: #""(?:openapi|swagger)"\s*:"#, options: .regularExpression) != nil,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["openapi"] != nil || object["swagger"] != nil,
              let paths = object["paths"] as? [String: Any] else { return nil }
        let servers = (object["servers"] as? [[String: Any]])?.compactMap { $0["url"] as? String } ?? []
        let prefix = prefix(basePath: object["basePath"] as? String, servers: servers)
        let string = text as NSString
        var operations: [Operation] = []
        for (path, item) in paths.sorted(by: { $0.key < $1.key }) where path.hasPrefix("/") {
            guard let item = item as? [String: Any] else { continue }
            let offset = string.range(of: "\"" + path + "\"").location
            let line = offset == NSNotFound ? 1 : string.substring(to: offset).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            for (method, operation) in item.sorted(by: { $0.key < $1.key }) where EndpointExtractor.methods.contains(method.uppercased()) {
                operations.append(Operation(method: method.uppercased(), path: EndpointExtractor.join(prefix, path), line: line,
                                            operationID: (operation as? [String: Any])?["operationId"] as? String))
            }
        }
        return operations
    }
}
