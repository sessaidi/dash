import Foundation
import Testing
@testable import Dash

/// Big tool results are cut before they reach the model, at a line, with a way to ask for less.
struct ResultBudgetTests {
    @Test func smallResultsAreUntouched() {
        #expect(ResultBudget.fit("a\nb", limit: 10) == "a\nb")
    }

    @Test func bigResultsAreCutAtALine() {
        let text = (1...100).map { "row \($0)" }.joined(separator: "\n")
        let cut = ResultBudget.fit(text, limit: 100)
        let kept = cut.components(separatedBy: "\n[Cut:").first ?? ""
        #expect(kept.count <= 100 && kept.hasSuffix(text.prefix(kept.count).split(separator: "\n").last.map(String.init) ?? "-"))
        #expect(!kept.hasSuffix("\n") && cut.contains("of \(text.count.formatted()) characters") && cut.contains("| take"))
    }
}
