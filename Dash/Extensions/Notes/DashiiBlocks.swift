import Foundation

/// `@Dashii` blocks in a note: a request to Dashii whose answer is written back into the note.
///
/// Written either in full, with the answer as the body:
///
///     @Dashii(ask: "Look at the workspaces for LAF-1234 and give me a report", id: k3f9) {
///       …Dashii's answer…
///     }
///
/// or as a one-line shorthand, `@Dashii can you look at …` (also `@dashii,` and `@Dashii:`), which
/// renders the same and becomes the full form once answered.
enum DashiiBlocks {
    struct Block: Equatable {
        /// The question.
        let ask: String
        let id: String?
        /// Lines the block spans in the note (the directive through its closing brace).
        let lines: Range<Int>
        /// The current answer (the body), if any.
        let answer: String
    }

    nonisolated(unsafe) private static let shorthand = /^(\s*)@[Dd]ashii[,:]?\s+([^(\s].*)$/

    /// The note with shorthand lines turned into `@Dashii(ask: "…")` directives (same line count),
    /// so the Markdown parser sees a component.
    static func normalized(_ source: String) -> String {
        guard source.contains("ashii") else { return source }
        return source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let match = try? shorthand.wholeMatch(in: String(line)) else { return String(line) }
            return "\(match.1)@Dashii(ask: \(quote(String(match.2))))"
        }.joined(separator: "\n")
    }

    static func blocks(in source: String) -> [Block] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let match = try? shorthand.wholeMatch(in: line) {
                result.append(Block(ask: String(match.2).trimmingCharacters(in: .whitespaces), id: nil, lines: index..<(index + 1), answer: ""))
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("@Dashii(") {
                let arguments = Self.arguments(line)
                var end = index + 1
                var answer: [String] = []
                if line.trimmingCharacters(in: .whitespaces).hasSuffix("{") {
                    // The body runs to the brace that closes this one (nested components have their own).
                    var depth = 1
                    while end < lines.count {
                        let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                        if trimmed == "}" { depth -= 1 } else if trimmed.hasSuffix("{") { depth += 1 }
                        end += 1
                        if depth == 0 { break }
                        answer.append(lines[end - 1])
                    }
                }
                result.append(Block(ask: arguments["ask"] ?? "", id: arguments["id"], lines: index..<end, answer: dedent(answer).joined(separator: "\n")))
                index = end
                continue
            }
            index += 1
        }
        return result
    }

    /// Writes `answer` into the block whose id (or question) is `reference`, in the full form with an id.
    static func answering(_ reference: String, with answer: String, in source: String) throws -> String {
        let all = blocks(in: source)
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        guard let block = all.first(where: { $0.id == wanted }) ?? all.first(where: { $0.ask == wanted })
                ?? all.first(where: { $0.ask.localizedCaseInsensitiveContains(wanted) }) else {
            throw ToolErrorMessage("No @Dashii block “\(reference)” in this note.")
        }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indent = String(lines[block.lines.lowerBound].prefix { $0 == " " })
        let id = block.id ?? newID()
        let body = answer.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : indent + "  " + $0 }
        let replacement = ["\(indent)@Dashii(ask: \(quote(block.ask)), id: \(id)) {"] + body + ["\(indent)}"]
        lines.replaceSubrange(block.lines, with: replacement)
        return lines.joined(separator: "\n")
    }

    static func newID() -> String { String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6)) }

    /// `name: value` pairs of a directive line; values may be "quoted" (with \" escapes).
    static func arguments(_ line: String) -> [String: String] {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return [:] }
        let inner = Array(line[line.index(after: open)..<close])
        var result: [String: String] = [:]
        var index = 0
        func skipSpaces() { while index < inner.count, inner[index] == " " || inner[index] == "," { index += 1 } }
        while index < inner.count {
            skipSpaces()
            var name = ""
            while index < inner.count, inner[index] != ":" { name.append(inner[index]); index += 1 }
            index += 1
            while index < inner.count, inner[index] == " " { index += 1 }
            var value = ""
            if index < inner.count, inner[index] == "\"" {
                index += 1
                while index < inner.count, inner[index] != "\"" {
                    if inner[index] == "\\", index + 1 < inner.count { index += 1 }
                    value.append(inner[index])
                    index += 1
                }
                index += 1
            } else {
                while index < inner.count, inner[index] != "," { value.append(inner[index]); index += 1 }
            }
            let key = name.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value.trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
    }
}
