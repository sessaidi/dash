import Foundation

/// Code owners from CODEOWNERS (`.github/`, the root or `docs/`, the first found wins, as on
/// GitHub): `owner:<@org/team, @user or email>` nodes, and one `owns` ref per rule. The link pass
/// applies the rules to the repository's files (the last matching rule wins) and writes as few
/// edges as say it all: `owner —owns→ repo` when one set of owners has everything, else
/// `—owns→ dir` where everything below shares the owners and the parent doesn't, and `—owns→ file`
/// for the exceptions. An email owner is `—about→` the person of that email (git authors).
struct OwnershipExtractor: CodeExtractor {
    let name = "owners"
    var sharedKinds: [String] { ["owner"] }
    static let refKind = "owns"
    /// Where GitHub looks, in order.
    static let locations = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]

    static func id(_ owner: String) -> String { "owner:" + owner }

    func accepts(path: String, language: String) -> Bool { language == "codeowners" }

    func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        var owners = Set<String>()
        for (index, raw) in file.text.components(separatedBy: "\n").enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            // GitLab section headers ("[Docs] @docs-team") aren't rules.
            guard !line.isEmpty, !line.hasPrefix("["), !line.hasPrefix("^[") else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let rule = tokens.dropFirst().filter { $0.contains("@") }
            owners.formUnion(rule)
            result.refs.append(KnowledgeRef(src: file.fileID, kind: Self.refKind, names: [tokens[0]] + rule, line: index + 1))
        }
        for owner in owners.sorted() {
            let kind = owner.hasPrefix("@") ? (owner.contains("/") ? "team" : "user") : "email"
            result.nodes.append(KnowledgeNode(id: Self.id(owner), kind: "owner", name: owner, qualified: owner, language: kind,
                                              signature: "Code owner " + owner, source: "code"))
            // Git history adds the person (read after the file); until then the edge leads nowhere.
            if kind == "email" { result.edges.append(KnowledgeEdge(src: Self.id(owner), dst: "person:" + owner.lowercased(), kind: "about")) }
        }
        return result
    }

    /// A CODEOWNERS pattern as a regular expression over repository paths: gitignore-style
    /// (`*`, `**`, `?`; anchored when it has a slash before its end), a trailing `/*` matching
    /// only the files directly in that folder.
    static func regex(_ pattern: String) -> NSRegularExpression? {
        var body = pattern
        let directOnly = body.hasSuffix("/*")
        let anchored = body.hasPrefix("/") || body.dropLast().contains("/")
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if directOnly { body = String(body.dropLast(2)) }
        var expression = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            if character == "*", next < body.endIndex, body[next] == "*" {
                let after = body.index(after: next)
                if after < body.endIndex, body[after] == "/" {
                    expression += "(?:.*/)?"
                    index = body.index(after: after)
                } else {
                    expression += ".*"
                    index = after
                }
                continue
            }
            switch character {
            case "*": expression += "[^/]*"
            case "?": expression += "[^/]"
            default: expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = next
        }
        if body.isEmpty { expression = ".*" }
        let prefix = anchored ? "^" : "^(?:.*/)?"
        let suffix = directOnly ? "/[^/]+$" : "(?:/.*)?$"
        return try? NSRegularExpression(pattern: prefix + expression + suffix)
    }

    /// path → owners (sorted; empty when the last matching rule has none, absent when none matches).
    static func owners(of files: [String], rules: [(pattern: String, owners: [String])]) -> [String: [String]] {
        let compiled = rules.compactMap { rule in regex(rule.pattern).map { ($0, rule.owners.sorted()) } }
        var result: [String: [String]] = [:]
        for path in files {
            let range = NSRange(location: 0, length: (path as NSString).length)
            if let rule = compiled.last(where: { $0.0.firstMatch(in: path, range: range) != nil }) { result[path] = rule.1 }
        }
        return result
    }

    /// The fewest (owner, target) pairs saying who owns what: "" is the repository, "dir/…" a
    /// folder, others files.
    static func assignments(_ owned: [String: [String]], files: [String]) -> [(owners: [String], target: String)] {
        var children: [String: [String]] = [:]
        var directories = Set<String>([""])
        for path in files {
            var child = path
            var parent = (path as NSString).deletingLastPathComponent
            children[parent, default: []].append(child)
            while !parent.isEmpty, directories.insert(parent).inserted {
                child = parent
                parent = (parent as NSString).deletingLastPathComponent
                children[parent, default: []].append("dir/" + child)
            }
        }
        // A folder's owners when everything below agrees (nil: mixed or unowned).
        var uniform: [String: [String]?] = [:]
        func owners(_ node: String) -> [String]? {
            if !node.hasPrefix("dir/") && node != "" { return owned[node].flatMap { $0.isEmpty ? nil : $0 } }
            let folder = node == "" ? "" : String(node.dropFirst(4))
            if let known = uniform[folder] { return known }
            let below = (children[folder] ?? []).map(owners)
            let first = below.first ?? nil
            let value = first != nil && below.allSatisfy { $0 == first } ? first : nil
            uniform[folder] = value
            return value
        }
        // Down from the root: a uniform folder is one assignment; a mixed one hands down to its children.
        var result: [(owners: [String], target: String)] = []
        func walk(_ folder: String) {
            let node = folder.isEmpty ? "" : "dir/" + folder
            if let mine = owners(node) {
                result.append((mine, node))
                return
            }
            for child in children[folder] ?? [] {
                if child.hasPrefix("dir/") {
                    walk(String(child.dropFirst(4)))
                } else if let fileOwners = owners(child) {
                    result.append((fileOwners, child))
                }
            }
        }
        walk("")
        return result
    }
}

/// The link pass for code owners.
enum OwnerLinks {
    static func link(repo: String, root: String, refs: [(file: String, ref: KnowledgeRef)], store: KnowledgeStore) async throws -> [KnowledgeEdge] {
        let rules = refs.filter { $0.ref.kind == OwnershipExtractor.refKind }
        guard !rules.isEmpty else { return [] }
        let filePrefix = "file:" + root + "/"
        let chosen = OwnershipExtractor.locations.first { location in rules.contains { $0.file == filePrefix + location } } ?? String(rules[0].file.dropFirst(filePrefix.count))
        let ordered = rules.filter { $0.file == filePrefix + chosen }.map(\.ref).sorted { $0.line < $1.line }
        let files = try await store.fileHashes(repo: repo).keys.sorted()
        let owned = OwnershipExtractor.owners(of: files, rules: ordered.compactMap { ref in ref.names.first.map { ($0, Array(ref.names.dropFirst())) } })
        var edges: [KnowledgeEdge] = []
        for (owners, target) in OwnershipExtractor.assignments(owned, files: files) {
            let dst = target.isEmpty ? repo : target.hasPrefix("dir/") ? "dir:" + root + "/" + target.dropFirst(4) : filePrefix + target
            edges += owners.map { KnowledgeEdge(src: OwnershipExtractor.id($0), dst: dst, kind: "owns", source: ExtractionLinks.source) }
        }
        return edges
    }
}
