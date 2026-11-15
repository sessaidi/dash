import Foundation
import Testing
@testable import Dash

/// Code blocks in notes are coloured by token.
struct SyntaxHighlighterTests {
    func kinds(_ code: String, _ language: String) -> [(String, SyntaxHighlighter.Token)] {
        SyntaxHighlighter.tokens(code, language: SyntaxHighlighter.language(language)!).filter { $0.1 != .plain }
    }

    @Test func goTokens() {
        let runs = kinds("func Serve(port string) error {\n\t// start\n\treturn http.ListenAndServe(\":\" + port, nil) // 8080\n}", "go")
        #expect(runs.contains { $0 == ("func", .keyword) } && runs.contains { $0 == ("Serve", .function) })
        #expect(runs.contains { $0 == ("// start", .comment) } && runs.contains { $0 == ("\":\"", .string) })
        #expect(runs.contains { $0 == ("ListenAndServe", .function) } && runs.contains { $0 == ("nil", .keyword) })
    }

    @Test func swiftPythonYamlSql() {
        #expect(kinds("@MainActor final class Store: Sendable { let n = 42 }", "swift").map(\.1) == [.attribute, .keyword, .keyword, .type, .type, .keyword, .number])
        #expect(kinds("def run(x):  # go\n    return 'ok'", "python").map(\.1) == [.keyword, .function, .comment, .keyword, .string])
        #expect(kinds("env:\n  - name: PORT\n    value: \"8080\"", "yaml").first?.1 == .type)
        #expect(kinds("SELECT name FROM nodes WHERE kind = 'env'", "sql").map(\.1) == [.keyword, .keyword, .keyword, .string])
    }

    @Test func unknownLanguagesStayPlain() {
        #expect(SyntaxHighlighter.language("brainfuck") == nil)
        #expect(String(SyntaxHighlighter.highlight("a b", language: nil, scheme: .light).characters) == "a b")
        // Text is never lost or reordered.
        let code = "let s = \"a \\\"q\\\" b\" /* c */ + 1"
        #expect(SyntaxHighlighter.tokens(code, language: SyntaxHighlighter.language("swift")!).map(\.0).joined() == code)
    }
}
