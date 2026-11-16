import Foundation

/// gRPC services, their rpcs and protobuf messages, from `.proto` files; and the hand-written Go,
/// TypeScript/JavaScript and Python code implementing or calling a service. The code only names
/// the service (`RegisterInvoicesServer`, `NewInvoicesClient`, `InvoicesStub`), and the `.proto`
/// is often in another repository, so those are refs `ServiceLinks` resolves across repositories.
/// Generated code (`*.pb.go`, `*_pb2_grpc.py`, …) is skipped: it declares every name of the service.
struct ProtobufExtractor: CodeExtractor {
    let name = "proto"
    var sharedKinds: [String] { ["rpc_service", "rpc", "message"] }

    func accepts(path: String, language: String) -> Bool {
        guard !SourceScan.isTest(path) else { return false }
        return language == "protobuf" || (["go", "typescript", "javascript", "python"].contains(language) && !Self.isGenerated(path))
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        file.language == "protobuf" ? Self.definitions(file) : Self.references(file)
    }

    static func isGenerated(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return [".pb.go", ".pb.gw.go", ".connect.go", "_pb2.py", "_pb2_grpc.py", "_pb2.pyi", "_pb.js", "_pb.ts", "_pb.d.ts",
                "_grpc_pb.js", "_grpc_pb.ts", "_grpc_pb.d.ts", "_connect.ts", "_connect.js", "_grpc_web_pb.js"].contains { name.hasSuffix($0) }
    }

    static func serviceID(_ package: String, _ service: String) -> String { "grpc:" + (package.isEmpty ? "" : package + ".") + service }
    static func messageID(_ package: String, _ message: String) -> String { "proto:" + (package.isEmpty ? "" : package + ".") + message }

    // MARK: Definitions

    static func definitions(_ file: ExtractionInput) -> Extraction {
        let proto = ProtoFile.parse(file.text)
        var result = Extraction()
        let package = proto.package
        let qualifier = package.isEmpty ? "" : package + "."
        for service in proto.services {
            let id = serviceID(package, service.name)
            let names = service.rpcs.map(\.name)
            result.nodes.append(KnowledgeNode(id: id, kind: "rpc_service", name: service.name, qualified: qualifier + service.name, path: file.path,
                                              line: service.line, language: "grpc",
                                              signature: "service \(qualifier + service.name): " + names.prefix(20).joined(separator: ", ") + (names.count > 20 ? ", …" : ""),
                                              source: "code"))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            for rpc in service.rpcs {
                let rpcID = id + "/" + rpc.name
                result.nodes.append(KnowledgeNode(id: rpcID, kind: "rpc", name: rpc.name, qualified: qualifier + service.name + "/" + rpc.name,
                                                  path: file.path, line: rpc.line, language: "grpc", signature: rpc.signature, source: "code"))
                result.edges.append(KnowledgeEdge(src: rpcID, dst: file.fileID, kind: "defined_in"))
                result.edges.append(KnowledgeEdge(src: id, dst: rpcID, kind: "contains"))
            }
        }
        for message in proto.messages {
            let id = messageID(package, message.name)
            let fields = message.fields.prefix(30).joined(separator: ", ") + (message.fields.count > 30 ? ", …" : "")
            result.nodes.append(KnowledgeNode(id: id, kind: "message", name: String(message.name.split(separator: ".").last ?? ""),
                                              qualified: qualifier + message.name, path: file.path, line: message.line, language: "protobuf",
                                              signature: "message \(message.name) { \(fields) }", source: "code"))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
        }
        return result
    }

    // MARK: Code using a service

    /// Refs from the code to the service it implements or calls: candidate service names (best
    /// first) and, from a Go import, `import:<path>` to tell same-named services apart.
    static func references(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        func add(_ kind: String, _ name: String, at offset: Int, src: String? = nil, importPath: String? = nil) {
            guard !name.isEmpty else { return }
            let line = file.line(at: offset)
            var names = [name]
            if name.hasSuffix("Service"), name.count > 7 { names.append(String(name.dropLast(7))) }
            if let importPath { names.append("import:" + importPath) }
            result.refs.append(KnowledgeRef(src: src ?? file.symbol(at: line) ?? file.fileID, kind: kind, names: names, line: line))
        }
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            for match in file.matches(SourceScan.regex(pattern)) { body(match) }
        }
        switch file.language {
        case "go":
            guard file.text.contains("Server") || file.text.contains("Client") || file.text.contains("Handler") else { return result }
            let imports = goImports(file.text)
            each(#"\b(?:(\w+)\.)?Register([A-Z]\w*?)Server\s*\("#) { match in
                add("implements", file.text(match.range(at: 2)), at: match.range.location, importPath: imports[file.text(match.range(at: 1))])
            }
            each(#"\b(?:(\w+)\.)?Unimplemented([A-Z]\w*?)Server\b"#) { match in
                add("implements", file.text(match.range(at: 2)), at: match.range.location, importPath: imports[file.text(match.range(at: 1))])
            }
            each(#"\b(\w+connect)\.New([A-Z]\w*?)(Handler|Client)\s*\("#) { match in
                add(file.text(match.range(at: 3)) == "Handler" ? "implements" : "calls_rpc", file.text(match.range(at: 2)), at: match.range.location,
                    importPath: imports[file.text(match.range(at: 1))])
            }
            each(#"\b(\w+)\.New([A-Z]\w*?)Client\s*\(\s*[^\s)]"#) { match in
                let alias = file.text(match.range(at: 1))
                guard !alias.hasSuffix("connect"), let path = imports[alias] else { return }
                add("calls_rpc", file.text(match.range(at: 2)), at: match.range.location, importPath: path)
            }
        case "python":
            guard file.text.contains("_pb2_grpc") || file.text.contains("Servicer") else { return result }
            each(#"(?m)^[ \t]*class\s+\w+\s*\([^)]*?\b(\w+)Servicer\s*\)"#) { match in
                add("implements", file.text(match.range(at: 1)), at: match.range.location)
            }
            each(#"\badd_(\w+)Servicer_to_server\s*\("#) { match in add("implements", file.text(match.range(at: 1)), at: match.range.location) }
            each(#"\b(\w+)Stub\s*\("#) { match in add("calls_rpc", file.text(match.range(at: 1)), at: match.range.location) }
        default:
            let lower = file.text.lowercased()
            guard lower.contains("grpc") || lower.contains("_pb") || lower.contains("connect") else { return result }
            each(#"\bnew\s+(\w+?)(?:Promise)?Client\s*\("#) { match in add("calls_rpc", file.text(match.range(at: 1)), at: match.range.location) }
            each(#"\bcreate(?:Promise|Callback)?Client\s*\(\s*(\w+)"#) { match in add("calls_rpc", file.text(match.range(at: 1)), at: match.range.location) }
            each(#"\.addService\s*\(\s*(?:\w+\.)?(\w+)\s*,"#) { match in add("implements", file.text(match.range(at: 1)), at: match.range.location) }
            each(#"\.getService(?:<[^>]*>)?\(\s*['"](\w+)['"]"#) { match in add("calls_rpc", file.text(match.range(at: 1)), at: match.range.location) }
            // NestJS: the decorated method implements one rpc of the service.
            each(#"@GrpcMethod\(\s*['"](\w+)['"]"#) { match in
                let line = file.line(at: match.range.location)
                add("implements", file.text(match.range(at: 1)), at: match.range.location, src: file.symbol(after: line, within: 4)?.id)
            }
        }
        return result
    }

    /// Go import aliases (or last path elements) → import paths.
    static func goImports(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in SourceScan.matches(#"(?m)^\s*(?:import\s+)?(?:([A-Za-z_]\w*)\s+)?"([^"\s]+)"\s*$"#, in: text) {
            let path = match[2]
            result[match[1].isEmpty ? (path as NSString).lastPathComponent : match[1]] = path
        }
        return result
    }
}

/// What a `.proto` file declares, read from its tokens (comments and strings aside).
struct ProtoFile: Equatable {
    struct Service: Equatable {
        var name: String
        var line: Int
        var rpcs: [RPC] = []
    }
    struct RPC: Equatable {
        var name: String
        var request: String
        var response: String
        var clientStreaming = false
        var serverStreaming = false
        var line: Int

        var signature: String {
            "rpc \(name)(\(clientStreaming ? "stream " : "")\(request)) returns (\(serverStreaming ? "stream " : "")\(response))"
        }
    }
    struct Message: Equatable {
        /// Nested messages are `Outer.Inner`.
        var name: String
        var fields: [String]
        var line: Int
    }

    var package = ""
    var services: [Service] = []
    var messages: [Message] = []

    static func parse(_ text: String) -> ProtoFile {
        var reader = Reader(tokens: tokens(text))
        return reader.file()
    }

    struct Token: Equatable {
        var text: String
        var line: Int
    }

    static func tokens(_ text: String) -> [Token] {
        let units = Array(text.utf16)
        var result: [Token] = []
        var index = 0
        var line = 1
        func isWord(_ unit: unichar) -> Bool { SourceScan.isIdentifier(unit) || unit == 46 }
        while index < units.count {
            let unit = units[index]
            if unit == 10 { line += 1; index += 1; continue }
            if SourceScan.isSpace(unit) { index += 1; continue }
            if unit == 47, index + 1 < units.count, units[index + 1] == 47 {
                while index < units.count, units[index] != 10 { index += 1 }
                continue
            }
            if unit == 47, index + 1 < units.count, units[index + 1] == 42 {
                index += 2
                while index + 1 < units.count, !(units[index] == 42 && units[index + 1] == 47) {
                    if units[index] == 10 { line += 1 }
                    index += 1
                }
                index += 2
                continue
            }
            if unit == 34 || unit == 39 {
                let start = index
                index += 1
                while index < units.count, units[index] != unit, units[index] != 10 {
                    if units[index] == 92 { index += 1 }
                    index += 1
                }
                index += 1
                result.append(Token(text: String(utf16CodeUnits: Array(units[start..<min(index, units.count)]), count: min(index, units.count) - start), line: line))
                continue
            }
            if isWord(unit) {
                let start = index
                while index < units.count, isWord(units[index]) { index += 1 }
                result.append(Token(text: String(utf16CodeUnits: Array(units[start..<index]), count: index - start), line: line))
                continue
            }
            result.append(Token(text: String(utf16CodeUnits: [unit], count: 1), line: line))
            index += 1
        }
        return result
    }

    private struct Reader {
        let tokens: [Token]
        var index = 0

        var current: String { index < tokens.count ? tokens[index].text : "" }
        var line: Int { index < tokens.count ? tokens[index].line : 0 }
        var done: Bool { index >= tokens.count }

        mutating func file() -> ProtoFile {
            var result = ProtoFile()
            while !done {
                switch current {
                case "package":
                    index += 1
                    result.package = current.hasPrefix(".") ? String(current.dropFirst()) : current
                    skipStatement()
                case "syntax", "edition", "import", "option":
                    skipStatement()
                case "service":
                    if let service = service() { result.services.append(service) }
                case "message":
                    message(prefix: "", into: &result.messages)
                case "enum", "extend":
                    skipBlock()
                default:
                    index += 1
                }
            }
            return result
        }

        /// Past the next `;` at this level (an option's `{ … }` value included).
        mutating func skipStatement() {
            var depth = 0
            while !done {
                let token = current
                index += 1
                if token == "{" { depth += 1 } else if token == "}" { depth -= 1; if depth < 0 { index -= 1; return } } else if token == ";", depth == 0 { return }
            }
        }

        /// Past the `{ … }` block that starts at or after the current token.
        mutating func skipBlock() {
            while !done, current != "{" {
                if current == ";" { index += 1; return }
                index += 1
            }
            var depth = 0
            while !done {
                let token = current
                index += 1
                if token == "{" { depth += 1 } else if token == "}" { depth -= 1; if depth == 0 { return } }
            }
        }

        mutating func service() -> Service? {
            index += 1
            guard !done, current != "{" else { return nil }
            var service = Service(name: current, line: line)
            index += 1
            guard current == "{" else { return nil }
            index += 1
            while !done, current != "}" {
                if current == "rpc" {
                    let start = line
                    index += 1
                    let name = current
                    index += 1
                    guard let request = type(), current == "returns" else { skipStatement(); continue }
                    index += 1
                    guard let response = type() else { skipStatement(); continue }
                    service.rpcs.append(RPC(name: name, request: request.name, response: response.name,
                                            clientStreaming: request.stream, serverStreaming: response.stream, line: start))
                    if current == "{" { skipBlock() } else if current == ";" { index += 1 }
                } else if current == "option" {
                    skipStatement()
                } else {
                    index += 1
                }
            }
            index += 1
            return service
        }

        /// `( [stream] Type )`.
        mutating func type() -> (name: String, stream: Bool)? {
            guard current == "(" else { return nil }
            index += 1
            var stream = false
            if current == "stream", index + 1 < tokens.count, tokens[index + 1].text != ")" { stream = true; index += 1 }
            let name = current
            index += 1
            guard current == ")" else { return nil }
            index += 1
            return (name.hasPrefix(".") ? String(name.dropFirst()) : name, stream)
        }

        mutating func message(prefix: String, into messages: inout [Message]) {
            index += 1
            guard !done, current != "{" else { return }
            let name = prefix.isEmpty ? current : prefix + "." + current
            let start = line
            index += 1
            guard current == "{" else { return }
            index += 1
            var fields: [String] = []
            var oneofs = 0
            let slot = messages.count
            messages.append(Message(name: name, fields: [], line: start))
            while !done {
                switch current {
                case "}":
                    index += 1
                    if oneofs == 0 { messages[slot].fields = fields; return }
                    oneofs -= 1
                case "message":
                    message(prefix: name, into: &messages)
                case "enum", "extend", "group":
                    skipBlock()
                case "option", "reserved", "extensions":
                    skipStatement()
                case "oneof":
                    index += 2
                    if current == "{" { index += 1; oneofs += 1 }
                case ";":
                    index += 1
                default:
                    // `[repeated] Type name = 1 [options];`, `map<K, V> name = 2;`
                    var previous = ""
                    var depth = 0
                    while !done {
                        let token = current
                        if token == "[" || token == "<" { depth += 1 } else if token == "]" || token == ">" { depth -= 1 }
                        if token == "=", depth == 0, !previous.isEmpty, !fields.contains(previous) { fields.append(previous) }
                        if token == "}" && depth <= 0 { break }
                        index += 1
                        if token == ";" && depth <= 0 { break }
                        previous = token
                    }
                }
            }
            messages[slot].fields = fields
        }
    }
}
