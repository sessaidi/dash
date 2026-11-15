import Foundation

/// Configuration and documents, read for what they declare and point at:
/// - Terraform: resources, data sources, modules, variables, outputs, providers; references
///   (`module.x`, `var.y`, `aws_s3_bucket.logs`) become calls, module sources become imports;
/// - YAML: Kubernetes resources ("Deployment/api") with their images, or top-level keys;
/// - TOML: tables; JSON: package.json scripts and dependencies, or top-level keys;
/// - Makefile: targets and includes; Markdown: headings, and links to other files.
enum StructuredParser {
    static func parse(_ text: String, language: String) -> ParsedFile {
        let lines = text.components(separatedBy: "\n")
        switch language {
        case "terraform": return terraform(lines)
        case "yaml": return yaml(lines)
        case "toml": return toml(lines)
        case "json": return json(text, lines: lines)
        case "makefile": return makefile(lines)
        case "markdown": return markdown(lines)
        default: return ParsedFile(language: language, symbols: [], imports: [])
        }
    }

    private static func symbol(_ name: String, _ kind: String, line: Int, end: Int, _ signature: String, calls: Set<String> = [],
                               container: String = "") -> ParsedFile.Symbol {
        ParsedFile.Symbol(name: name, kind: kind, container: container, line: line, endLine: max(end, line),
                          signature: String(signature.trimmingCharacters(in: .whitespaces).prefix(200)), calls: calls)
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    // MARK: Terraform

    private static func terraform(_ lines: [String]) -> ParsedFile {
        var symbols: [ParsedFile.Symbol] = []
        var imports: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let match = matches(#"^\s*(resource|data|module|variable|output|provider)\s+"([^"]+)"(?:\s+"([^"]+)")?\s*\{"#, in: line).first else {
                index += 1
                continue
            }
            // The block runs until its braces balance.
            var depth = 0
            var end = index
            for scan in index..<lines.count {
                depth += lines[scan].filter { $0 == "{" }.count - lines[scan].filter { $0 == "}" }.count
                end = scan
                if depth <= 0 { break }
            }
            let body = lines[index...end].joined(separator: "\n")
            let (keyword, first, second) = (match[1], match[2], match[3])
            let name: String = switch keyword {
            case "resource": "\(first).\(second)"
            case "data": "data.\(first).\(second)"
            case "module": "module.\(first)"
            case "variable": "var.\(first)"
            case "output": "output.\(first)"
            default: "provider.\(first)"
            }
            // What the block refers to: other resources, modules, variables, locals.
            var calls = Set<String>()
            for reference in matches(#"\b(module\.[\w-]+|var\.[\w-]+|data\.[\w-]+\.[\w-]+|local\.[\w-]+|[a-z][a-z0-9]*_[a-z0-9_]+\.[\w-]+)"#, in: body) {
                if reference[1] != name { calls.insert(reference[1]) }
            }
            if keyword == "module", let source = matches(#"source\s*=\s*"([^"]+)""#, in: body).first?[1] { imports.append(source) }
            symbols.append(symbol(name, keyword, line: index + 1, end: end + 1, line, calls: calls))
            index = end + 1
        }
        return ParsedFile(language: "terraform", symbols: symbols, imports: imports)
    }

    // MARK: YAML

    private static func yaml(_ lines: [String]) -> ParsedFile {
        // Split into documents ("---"); a document with apiVersion + kind is a Kubernetes resource.
        var documents: [(start: Int, end: Int)] = []
        var start = 0
        for (index, line) in lines.enumerated() where line.hasPrefix("---") {
            if index > start { documents.append((start, index - 1)) }
            start = index + 1
        }
        if start < lines.count { documents.append((start, lines.count - 1)) }

        var symbols: [ParsedFile.Symbol] = []
        var imports: [String] = []
        for document in documents {
            let body = lines[document.start...document.end]
            let text = body.joined(separator: "\n")
            if let kind = matches(#"(?m)^kind:\s*["']?([\w.-]+)"#, in: text).first?[1], text.range(of: #"(?m)^apiVersion:"#, options: .regularExpression) != nil {
                let name = matches(#"(?m)^metadata:\s*\n(?:\s+.*\n)*?\s+name:\s*["']?([\w.\-{}$ ]+?)["']?\s*$"#, in: text).first?[1] ?? kind
                let line = document.start + (body.firstIndex { $0.hasPrefix("kind:") }.map { $0 - document.start } ?? 0) + 1
                // Images it runs, and the config/secrets/services it points at by name.
                for image in matches(#"(?m)^\s*-?\s*image:\s*["']?([^\s"']+)"#, in: text) { imports.append("image:" + image[1]) }
                var calls = Set<String>()
                for reference in matches(#"(?m)^\s*-?\s*(?:name|configMapName|secretName|serviceName|claimName):\s*["']?([\w.-]+)"#, in: text) where reference[1] != name {
                    calls.insert(reference[1])
                }
                symbols.append(symbol(name, "k8s." + kind, line: line, end: document.end + 1, "\(kind)/\(name)", calls: calls))
            } else {
                for (offset, line) in body.enumerated() {
                    guard let key = matches(#"^([A-Za-z_][\w.\-/]*):(?:\s|$)"#, in: line).first?[1] else { continue }
                    symbols.append(symbol(key, "key", line: document.start + offset + 1, end: document.start + offset + 1, line))
                }
            }
        }
        return ParsedFile(language: "yaml", symbols: symbols, imports: Array(Set(imports)).sorted())
    }

    // MARK: TOML, JSON

    private static func toml(_ lines: [String]) -> ParsedFile {
        var symbols: [ParsedFile.Symbol] = []
        for (index, line) in lines.enumerated() {
            guard let table = matches(#"^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*$"#, in: line).first?[1] else { continue }
            if let last = symbols.indices.last { symbols[last].endLine = index }
            symbols.append(symbol(table, "table", line: index + 1, end: lines.count, line))
        }
        return ParsedFile(language: "toml", symbols: symbols, imports: [])
    }

    private static func json(_ text: String, lines: [String]) -> ParsedFile {
        guard text.utf8.count < 400_000, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedFile(language: "json", symbols: [], imports: [])
        }
        func line(of key: String) -> Int {
            (lines.firstIndex { $0.contains("\"\(key)\"") } ?? 0) + 1
        }
        var symbols: [ParsedFile.Symbol] = []
        var imports: [String] = []
        // package.json: its scripts, and dependencies as imports.
        if object["dependencies"] != nil || object["scripts"] != nil || object["devDependencies"] != nil {
            for (name, command) in (object["scripts"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                symbols.append(symbol(name, "script", line: line(of: name), end: line(of: name), "\(name): \(command)"))
            }
            for key in ["dependencies", "devDependencies", "peerDependencies"] {
                imports += (object[key] as? [String: Any])?.keys.sorted() ?? []
            }
        } else {
            for key in object.keys.sorted() { symbols.append(symbol(key, "key", line: line(of: key), end: line(of: key), key)) }
        }
        return ParsedFile(language: "json", symbols: symbols, imports: imports)
    }

    // MARK: Makefile, Markdown

    private static func makefile(_ lines: [String]) -> ParsedFile {
        var symbols: [ParsedFile.Symbol] = []
        var imports: [String] = []
        for (index, line) in lines.enumerated() {
            if let include = matches(#"^-?include\s+(.+)$"#, in: line).first?[1] {
                imports += include.split(separator: " ").map(String.init)
            } else if let target = matches(#"^([A-Za-z0-9_.\-/%$(){}]+)\s*:(?!=)\s*([^=]*)$"#, in: line).first, !target[1].hasPrefix(".") {
                if let last = symbols.indices.last { symbols[last].endLine = index }
                // Prerequisites are the targets it depends on.
                let prerequisites = Set(target[2].split(separator: " ").map(String.init).filter { !$0.isEmpty })
                symbols.append(symbol(target[1], "target", line: index + 1, end: index + 1, line, calls: prerequisites))
            } else if line.hasPrefix("\t"), let last = symbols.indices.last {
                symbols[last].endLine = index + 1
                // `$(MAKE) other` and `make other` inside a recipe.
                for call in matches(#"(?:\$\(MAKE\)|\bmake)\s+([\w.-]+)"#, in: line) { symbols[last].calls.insert(call[1]) }
            }
        }
        return ParsedFile(language: "makefile", symbols: symbols, imports: imports)
    }

    private static func markdown(_ lines: [String]) -> ParsedFile {
        var symbols: [ParsedFile.Symbol] = []
        var imports: [String] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            if let heading = matches(#"^(#{1,4})\s+(.+?)\s*#*\s*$"#, in: line).first {
                let level = heading[1].count
                // A heading's section runs until the next heading of the same or a higher level.
                for previous in symbols.indices.reversed() where symbols[previous].endLine == lines.count {
                    if Int(symbols[previous].kind.dropFirst(1)) ?? 9 >= level { symbols[previous].endLine = index }
                }
                symbols.append(symbol(heading[2], "h\(level)", line: index + 1, end: lines.count, line))
            }
            // Links to files in the repository (not web links or anchors).
            for link in matches(#"\]\(([^)#\s]+)(?:#[^)]*)?\)"#, in: line) where !link[1].contains("://") && !link[1].hasPrefix("mailto:") {
                imports.append(link[1])
            }
        }
        return ParsedFile(language: "markdown", symbols: symbols, imports: Array(Set(imports)).sorted())
    }
}
