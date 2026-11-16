import Foundation

/// GraphQL schemas: types from `.graphql` files and `gql`/`graphql` templates in TypeScript and
/// JavaScript (`graphql:<Type>`), and the fields of the root types, Query, Mutation and
/// Subscription or what `schema { … }` names (`graphql:Query.user`), each `defined_in` its file.
/// Resolvers are `handled_by` edges: gqlgen methods (`func (r *queryResolver) User(`), Apollo
/// resolver maps (`Query: { user: getUser }`) and NestJS/TypeGraphQL `@Query()` methods, which
/// also declare their field (the schema is generated from the code there).
struct GraphQLExtractor: CodeExtractor {
    let name = "graphql"
    var sharedKinds: [String] { ["graphql_type", "graphql_field"] }

    func accepts(path: String, language: String) -> Bool {
        ["graphql", "go", "typescript", "javascript"].contains(language) && !SourceScan.isTest(path)
    }

    static func typeID(_ name: String) -> String { "graphql:" + name }
    static func fieldID(_ type: String, _ field: String) -> String { "graphql:" + type + "." + field }

    func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        switch file.language {
        case "graphql":
            result.add(Self.schema(GraphQLSchema.parse(file.text), in: file))
        case "go":
            guard file.text.contains("Resolver)") else { return result }
            result.add(Self.gqlgen(file))
        default:
            guard file.text.contains("gql") || file.text.contains("graphql") || file.text.contains("Query") else { return result }
            for template in file.matches(SourceScan.regex(#"\b(?:gql|graphql)\s*(?:<[^>`]*>)?\s*`"#)) {
                let start = template.range.location + template.range.length
                guard let end = file.units[start...].firstIndex(of: 96) else { continue }
                let body = file.text(NSRange(location: start, length: end - start)).replacingOccurrences(of: #"\$\{[^}]*\}"#, with: " ", options: .regularExpression)
                result.add(Self.schema(GraphQLSchema.parse(body, firstLine: file.line(at: start)), in: file))
            }
            result.add(Self.resolverMaps(file))
            result.add(Self.decoratedResolvers(file))
        }
        return result
    }

    // MARK: Schema

    static func schema(_ schema: GraphQLSchema, in file: ExtractionInput) -> Extraction {
        var result = Extraction()
        let roots = schema.roots
        for type in schema.types {
            let id = typeID(type.name)
            if !type.extends {
                let members = type.members.prefix(30).joined(separator: type.kind == "union" ? " | " : ", ") + (type.members.count > 30 ? ", …" : "")
                let body = switch type.kind {
                case "union": " = " + members
                case "scalar": ""
                default: (type.interfaces.isEmpty ? "" : " implements " + type.interfaces.joined(separator: " & ")) + " { \(members) }"
                }
                result.nodes.append(KnowledgeNode(id: id, kind: "graphql_type", name: type.name, qualified: type.name, path: file.path, line: type.line,
                                                  language: "graphql", signature: type.kind + " " + type.name + body, source: "code"))
                result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            }
            guard roots.contains(type.name) else { continue }
            for field in type.fields {
                let fieldID = fieldID(type.name, field.name)
                result.nodes.append(KnowledgeNode(id: fieldID, kind: "graphql_field", name: field.name, qualified: type.name + "." + field.name,
                                                  path: file.path, line: field.line, language: "graphql",
                                                  signature: type.name + "." + field.signature, source: "code"))
                result.edges.append(KnowledgeEdge(src: fieldID, dst: file.fileID, kind: "defined_in"))
                result.edges.append(KnowledgeEdge(src: id, dst: fieldID, kind: "contains"))
            }
        }
        return result
    }

    // MARK: Resolvers

    /// gqlgen: methods of `queryResolver`, `mutationResolver` and `subscriptionResolver`.
    static func gqlgen(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        for match in file.matches(SourceScan.regex(#"(?m)^func\s*\(\s*\w+\s+\*?(query|mutation|subscription)Resolver\s*\)\s*([A-Z]\w*)\s*\("#)) {
            let line = file.line(at: match.range.location)
            guard let index = file.parsed.symbols.firstIndex(where: { $0.line == line && $0.kind == "method" }) else { continue }
            let type = file.text(match.range(at: 1)).capitalized
            let method = file.text(match.range(at: 2))
            result.edges.append(KnowledgeEdge(src: fieldID(type, lowerFirst(method)), dst: file.symbolIDs[index], kind: "handled_by"))
        }
        return result
    }

    /// Apollo-style maps: `Query: { user: getUser, users(parent, args) { … }, plan: async () => … }`.
    static func resolverMaps(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        for match in file.matches(SourceScan.regex(#"\b(Query|Mutation|Subscription)\s*:\s*\{"#)) {
            let open = match.range.location + match.range.length - 1
            guard let entries = file.arguments(at: open, limit: 100_000) else { continue }
            let type = file.text(match.range(at: 1))
            for range in entries.ranges {
                let entry = file.text(range)
                guard let key = SourceScan.matches(#"^(?:async\s+)?['"]?([A-Za-z_]\w*)['"]?\s*(:|\()"#, in: entry).first else { continue }
                let id = fieldID(type, key[1])
                if key[2] == ":", let target = SourceScan.matches(#"^[^:]+:\s*([A-Za-z_$][\w$.]*)\s*$"#, in: entry).first?[1] {
                    let names = target.split(separator: ".").map(String.init)
                    result.refs.append(KnowledgeRef(src: id, kind: "handled_by", names: [names.suffix(2).joined(separator: "."), names.last ?? target], line: file.line(at: range.location)))
                } else if let symbol = file.symbol(at: file.line(at: range.location)) {
                    result.edges.append(KnowledgeEdge(src: id, dst: symbol, kind: "handled_by"))
                }
            }
        }
        return result
    }

    /// NestJS / TypeGraphQL: `@Query(() => User, { name: 'user' })` on a resolver method.
    static func decoratedResolvers(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        guard file.text.contains("@nestjs/graphql") || file.text.contains("type-graphql") else { return result }
        for match in file.matches(SourceScan.regex(#"(?m)^[ \t]*@(Query|Mutation|Subscription)\s*\("#)) {
            let open = match.range.location + match.range.length - 1
            let line = file.line(at: match.range.location)
            guard let method = file.symbol(after: line + 1, within: 6), let arguments = file.arguments(at: open) else { continue }
            let options = arguments.ranges.map(file.text).joined(separator: ",")
            let type = file.text(match.range(at: 1))
            let field = SourceScan.matches(#"\bname\s*:\s*['"](\w+)['"]"#, in: options).first?[1] ?? method.symbol.name
            let returns = SourceScan.matches(#"=>\s*(\[?\s*\w+\s*\]?)"#, in: options).first.map { ": " + $0[1].replacingOccurrences(of: " ", with: "") } ?? ""
            let id = fieldID(type, field)
            result.nodes.append(KnowledgeNode(id: id, kind: "graphql_field", name: field, qualified: type + "." + field, path: file.path, line: line,
                                              language: "graphql", signature: type + "." + field + returns + " → " + (method.symbol.container.isEmpty ? "" : method.symbol.container + ".") + method.symbol.name,
                                              source: "code"))
            result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
            result.edges.append(KnowledgeEdge(src: id, dst: method.id, kind: "handled_by"))
            result.edges.append(KnowledgeEdge(src: typeID(type), dst: id, kind: "contains"))
        }
        return result
    }

    private static func lowerFirst(_ name: String) -> String {
        // gqlgen exports `UserByID` for `userByID` and `ID` for `id`.
        let upper = name.prefix { $0.isUppercase }
        if upper.count == name.count { return name.lowercased() }
        if upper.count <= 1 { return name.prefix(1).lowercased() + name.dropFirst() }
        return upper.dropLast().lowercased() + name.dropFirst(upper.count - 1)
    }
}

/// The definitions of a GraphQL schema document (operations and fragments skipped).
struct GraphQLSchema: Equatable {
    struct TypeDefinition: Equatable {
        /// type, input, interface, enum, union or scalar.
        var kind: String
        var name: String
        var extends = false
        var interfaces: [String] = []
        /// Field names, enum values or union members.
        var members: [String] = []
        var fields: [Field] = []
        var line: Int
    }
    struct Field: Equatable {
        var name: String
        /// `user(id: ID!): User`
        var signature: String
        var line: Int
    }

    var types: [TypeDefinition] = []
    var schemaRoots: [String: String] = [:]

    /// The names of the root operation types.
    var roots: Set<String> {
        Set(["query", "mutation", "subscription"].map { schemaRoots[$0] ?? $0.capitalized })
    }

    static func parse(_ text: String, firstLine: Int = 1) -> GraphQLSchema {
        var reader = Reader(tokens: tokens(text, firstLine: firstLine))
        return reader.document()
    }

    struct Token: Equatable {
        var text: String
        var line: Int
        var isString = false
    }

    static func tokens(_ text: String, firstLine: Int = 1) -> [Token] {
        let units = Array(text.utf16)
        var result: [Token] = []
        var index = 0
        var line = firstLine
        while index < units.count {
            let unit = units[index]
            if unit == 10 { line += 1; index += 1; continue }
            if SourceScan.isSpace(unit) || unit == 44 { index += 1; continue }
            if unit == 35 {
                while index < units.count, units[index] != 10 { index += 1 }
                continue
            }
            if unit == 34 {
                let start = line
                if index + 2 < units.count, units[index + 1] == 34, units[index + 2] == 34 {
                    index += 3
                    while index + 2 < units.count, !(units[index] == 34 && units[index + 1] == 34 && units[index + 2] == 34) {
                        if units[index] == 10 { line += 1 }
                        index += 1
                    }
                    index += 3
                } else {
                    index += 1
                    while index < units.count, units[index] != 34, units[index] != 10 {
                        if units[index] == 92 { index += 1 }
                        index += 1
                    }
                    index += 1
                }
                result.append(Token(text: "\"", line: start, isString: true))
                continue
            }
            if SourceScan.isIdentifier(unit) || unit == 45 {
                let start = index
                index += 1
                while index < units.count, SourceScan.isIdentifier(units[index]) || units[index] == 46 { index += 1 }
                result.append(Token(text: String(utf16CodeUnits: Array(units[start..<index]), count: index - start), line: line))
                continue
            }
            if unit == 46, index + 2 < units.count, units[index + 1] == 46, units[index + 2] == 46 {
                result.append(Token(text: "...", line: line))
                index += 3
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

        var done: Bool { index >= tokens.count }
        var current: Token { index < tokens.count ? tokens[index] : Token(text: "", line: 0) }
        var name: String { current.isString ? "" : current.text }
        static let definitions: Set<String> = ["type", "input", "interface", "enum", "union", "scalar", "schema", "extend", "directive",
                                               "query", "mutation", "subscription", "fragment"]

        mutating func document() -> GraphQLSchema {
            var result = GraphQLSchema()
            while !done {
                if current.isString { index += 1; continue }
                var extends = false
                if name == "extend" { extends = true; index += 1 }
                switch name {
                case "schema":
                    index += 1
                    skipDirectives()
                    guard name == "{" else { continue }
                    index += 1
                    while !done, name != "}" {
                        let operation = name
                        index += 1
                        if name == ":" { index += 1; result.schemaRoots[operation] = name; index += 1 }
                    }
                    index += 1
                case "type", "input", "interface", "enum", "union", "scalar":
                    if let type = definition(extends: extends) { result.types.append(type) }
                case "directive":
                    index += 1
                    while !done, name != "on" { if name == "(" { skipGroup() } else { index += 1 } }
                    index += 1
                    if name == "|" { index += 1 }
                    while !done {
                        index += 1
                        guard name == "|" else { break }
                        index += 1
                    }
                case "query", "mutation", "subscription", "fragment", "{":
                    while !done, name != "{" { index += 1 }
                    skipGroup()
                default:
                    index += 1
                }
            }
            return result
        }

        mutating func definition(extends: Bool) -> TypeDefinition? {
            let kind = name
            index += 1
            guard !done, !current.isString else { return nil }
            var type = TypeDefinition(kind: kind, name: name, extends: extends, line: current.line)
            index += 1
            if name == "implements" {
                index += 1
                while !done, name == "&" || (!Self.definitions.contains(name) && name != "{" && name != "@" && !current.isString) {
                    if name != "&" { type.interfaces.append(name) }
                    index += 1
                }
            }
            skipDirectives()
            switch kind {
            case "union":
                guard name == "=" else { return type }
                index += 1
                if name == "|" { index += 1 }
                while !done, !current.isString {
                    type.members.append(name)
                    index += 1
                    guard name == "|" else { break }
                    index += 1
                }
            case "scalar":
                break
            case "enum":
                guard name == "{" else { return type }
                index += 1
                while !done, name != "}" {
                    if current.isString { index += 1; continue }
                    if name == "@" { skipDirectives(); continue }
                    type.members.append(name)
                    index += 1
                }
                index += 1
            default:
                guard name == "{" else { return type }
                index += 1
                while !done, name != "}" {
                    if current.isString { index += 1; continue }
                    let fieldLine = current.line
                    let fieldName = name
                    index += 1
                    var arguments: [String] = []
                    if name == "(" { arguments = argumentList() }
                    guard name == ":" else { continue }
                    index += 1
                    let fieldType = typeReference()
                    if name == "=" { index += 1; skipValue() }
                    skipDirectives()
                    type.members.append(fieldName)
                    let signature = fieldName + (arguments.isEmpty ? "" : "(" + arguments.joined(separator: ", ") + ")") + ": " + fieldType
                    type.fields.append(Field(name: fieldName, signature: signature, line: fieldLine))
                }
                index += 1
            }
            return type
        }

        /// `(id: ID!, filter: Filter = {…} @deprecated)` → ["id: ID!", "filter: Filter"].
        mutating func argumentList() -> [String] {
            index += 1
            var result: [String] = []
            while !done, name != ")" {
                if current.isString { index += 1; continue }
                if name == "@" { skipDirectives(); continue }
                let argument = name
                index += 1
                guard name == ":" else { continue }
                index += 1
                result.append(argument + ": " + typeReference())
                if name == "=" { index += 1; skipValue() }
            }
            index += 1
            return result
        }

        /// `[User!]!`
        mutating func typeReference() -> String {
            var result = ""
            if name == "[" {
                index += 1
                result = "[" + typeReference() + "]"
                if name == "]" { index += 1 }
            } else {
                result = name
                index += 1
            }
            if name == "!" { result += "!"; index += 1 }
            return result
        }

        /// A default value: a literal, a list or an object.
        mutating func skipValue() {
            if name == "[" || name == "{" { skipGroup() } else { index += 1 }
        }

        mutating func skipDirectives() {
            while !done, name == "@" {
                index += 2
                if name == "(" { skipGroup() }
            }
        }

        /// Past the bracketed group starting at the current token.
        mutating func skipGroup() {
            var depth = 0
            while !done {
                let token = current
                index += 1
                if token.isString { continue }
                if ["(", "[", "{"].contains(token.text) { depth += 1 } else if [")", "]", "}"].contains(token.text) { depth -= 1; if depth <= 0 { return } }
            }
        }
    }
}
