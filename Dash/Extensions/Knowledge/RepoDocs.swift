import DashKit
import Foundation

/// A repository's own documents, `doc:repo:<root>/<path>`: Markdown, AsciiDoc and reST files
/// (not changelogs, licences or test fixtures). Name: the title; signature: the text with secrets
/// masked, at most 20,000 characters (as documents from Confluence); summary: the section headings.
/// `doc —documents→ dir` for its folder (the repository at the root), `doc —about→ file/dir` for the
/// paths it links to or writes in backticks. Backticked identifiers and `GET /users/{id}` routes
/// are a `doc_about` ref the link pass resolves to the repository's symbols and routes.
struct RepoDocExtractor: CodeExtractor {
    let name = "docs"
    static let refKind = "doc_about"
    static let maxText = 20_000
    static let skippedNames = ["CHANGELOG", "CHANGES", "HISTORY", "LICENSE", "LICENCE", "NOTICE", "CODE_OF_CONDUCT", "AUTHORS", "CONTRIBUTORS"]

    static func id(root: String, path: String) -> String { "doc:repo:" + root + "/" + path }

    func accepts(path: String, language: String) -> Bool {
        guard ["markdown", "asciidoc", "rst"].contains(language), !SourceScan.isTest(path) else { return false }
        let name = (path as NSString).lastPathComponent.uppercased()
        return !Self.skippedNames.contains { name.hasPrefix($0) }
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        let text = file.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else { return Extraction() }
        let outline = Self.outline(text, language: file.language)
        let id = Self.id(root: file.root, path: file.path)
        var result = Extraction()
        let sections = outline.headings.prefix(30).joined(separator: " · ")
        let base = (file.fileName as NSString).deletingPathExtension
        let fallback = base.uppercased() == "README" ? ((file.directory.isEmpty ? file.repoName : (file.directory as NSString).lastPathComponent) + " " + base) : base
        result.nodes.append(KnowledgeNode(id: id, kind: "doc", name: outline.title ?? fallback, qualified: file.path,
                                          repo: file.repoID, path: file.path, line: 1, language: file.language,
                                          signature: String(Sanitizer.clean(text).prefix(Self.maxText)),
                                          summary: sections.isEmpty ? "" : String(("Sections: " + sections).prefix(600)), source: "code"))
        result.edges.append(KnowledgeEdge(src: id, dst: file.fileID, kind: "defined_in"))
        result.edges.append(KnowledgeEdge(src: id, dst: file.directory.isEmpty ? file.repoID : file.directoryID(file.directory), kind: "documents"))

        let mentions = Self.mentions(text)
        let paths = file.context.paths()
        var targets = Set<String>()
        for candidate in mentions.paths {
            let relative = candidate.removingPercentEncoding ?? candidate
            for base in [file.directory, ""] {
                guard let path = SourceScan.join(base, relative), !path.isEmpty, path != file.path else { continue }
                if paths.files.contains(path) { targets.insert("file:" + file.root + "/" + path); break }
                if paths.directories.contains(path) { targets.insert(file.directoryID(path)); break }
            }
        }
        result.edges += targets.sorted().map { KnowledgeEdge(src: id, dst: $0, kind: "about") }
        if !mentions.names.isEmpty { result.refs.append(KnowledgeRef(src: id, kind: Self.refKind, names: mentions.names)) }
        return result
    }

    /// The title (first top heading) and the section headings below it.
    static func outline(_ text: String, language: String) -> (title: String?, headings: [String]) {
        let lines = text.components(separatedBy: "\n")
        var title: String?
        var headings: [String] = []
        var fence = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("```") || line.hasPrefix("~~~") || (language == "asciidoc" && line.hasPrefix("----")) { fence.toggle(); continue }
            if fence { continue }
            var level = 0
            var heading = ""
            switch language {
            case "asciidoc":
                if let match = SourceScan.matches(#"^(=+)\s+(.+?)\s*$"#, in: line).first { level = match[1].count; heading = match[2] }
            case "rst":
                if index + 1 < lines.count, !line.trimmingCharacters(in: .whitespaces).isEmpty,
                   let underline = lines[index + 1].first, "=-~^*#".contains(underline),
                   lines[index + 1].count >= line.count, lines[index + 1].allSatisfy({ $0 == underline }) {
                    level = "=-~^*#".distance(from: "=-~^*#".startIndex, to: "=-~^*#".firstIndex(of: underline)!) + 1
                    heading = line.trimmingCharacters(in: .whitespaces)
                }
            default:
                if let match = SourceScan.matches(#"^(#{1,4})\s+(.+?)\s*#*\s*$"#, in: line).first { level = match[1].count; heading = match[2] }
            }
            guard level > 0, !heading.isEmpty else { continue }
            if level == 1 && title == nil { title = heading } else if level <= 3 { headings.append(heading) }
        }
        return (title, headings)
    }

    /// Paths it links to or writes in backticks; and refs: "symbol:<name>" for backticked
    /// identifiers that look like code, "endpoint:<METHOD> <path>" for routes it names.
    static func mentions(_ text: String) -> (paths: [String], names: [String]) {
        var paths: [String] = []
        var names: [String] = []
        func add(_ name: String) { if !names.contains(name) { names.append(name) } }
        var prose: [String] = []
        var fence = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle(); continue }
            if !fence { prose.append(line) }
        }
        let body = prose.joined(separator: "\n")
        for match in SourceScan.matches(#"\]\(([^)\s#]+)(?:#[^)]*)?\)|(?:link|xref):([^\[\s]+)\["#, in: body) {
            let target = match[1].isEmpty ? match[2] : match[1]
            if !target.contains("://"), !target.hasPrefix("mailto:") { paths.append(target) }
        }
        for match in SourceScan.matches(#"`([^`\n]{2,100})`"#, in: body) {
            let span = match[1].trimmingCharacters(in: .whitespaces)
            if let route = SourceScan.matches(#"^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(/\S*)$"#, in: span).first {
                add(EndpointExtractor.id(method: route[1], path: EndpointExtractor.normalize(route[2])))
                continue
            }
            // `handlers.go` may be a file, `Users.Get` a method: whichever resolves.
            if span.range(of: #"^[\w./-]+$"#, options: .regularExpression) != nil, span.contains("/") || span.range(of: #"\.[a-z]{1,5}$"#, options: .regularExpression) != nil {
                paths.append(span)
            }
            if span.range(of: #"^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*(\(\))?$"#, options: .regularExpression) != nil,
               span.contains(where: { $0.isUppercase || $0 == "_" || $0 == "." || $0 == "(" }) {
                let name = span.replacingOccurrences(of: "()", with: "").split(separator: ".").last.map(String.init) ?? span
                if name.count >= 3 { add("symbol:" + name) }
            }
        }
        for match in SourceScan.matches(#"\b(GET|POST|PUT|PATCH|DELETE)\s+(/[\w/{}:.\-]*)"#, in: text) {
            add(EndpointExtractor.id(method: match[1], path: EndpointExtractor.normalize(match[2])))
        }
        return (paths, names)
    }
}

/// The link pass for docs: backticked names to the repository's code symbols (the only one inside
/// the doc's folder at 0.8, the only one in the repository at 0.6) and routes to the ones it defines.
enum DocLinks {
    static func link(repo: String, root: String, refs: [KnowledgeRef], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        guard !refs.isEmpty else { return [] }
        let index = try await store.symbolIndex(repo: repo)
        let endpoints = Set(try await store.definitions(repo: repo, idPrefix: "endpoint:").map(\.id))
        let prefix = "doc:repo:" + root + "/"
        var edges: [KnowledgeEdge] = []
        for ref in refs {
            let folder = (String(ref.src.dropFirst(prefix.count)) as NSString).deletingLastPathComponent
            for name in ref.names {
                if name.hasPrefix("endpoint:") {
                    if endpoints.contains(name) { edges.append(KnowledgeEdge(src: ref.src, dst: name, kind: "about", weight: 0.9, source: ExtractionLinks.source)) }
                    continue
                }
                guard name.hasPrefix("symbol:") else { continue }
                let code = (index[String(name.dropFirst(7))] ?? []).filter { id in
                    let path = CodeIndexer.path(ofSymbol: id, root: root)
                    return CodeParser.language(of: path).map { !CodeParser.structured.contains($0) } ?? false
                }
                let inside = folder.isEmpty ? code : code.filter { CodeIndexer.path(ofSymbol: $0, root: root).hasPrefix(folder + "/") }
                if inside.count == 1, !folder.isEmpty {
                    edges.append(KnowledgeEdge(src: ref.src, dst: inside[0], kind: "about", weight: 0.8, source: ExtractionLinks.source))
                } else if code.count == 1 {
                    edges.append(KnowledgeEdge(src: ref.src, dst: code[0], kind: "about", weight: 0.6, source: ExtractionLinks.source))
                }
            }
        }
        return edges
    }
}
