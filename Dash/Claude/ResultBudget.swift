import Foundation

/// How much of a tool result goes back to the model. Results stay in the conversation and are
/// read again on every later turn, so a 50,000-character answer costs far more than once: past
/// the limit the result is cut at a line, with a note on how to ask for less. The chat still
/// shows the whole result.
enum ResultBudget {
    static let limit = 12_000

    static func fit(_ text: String, limit: Int = limit) -> String {
        guard text.count > limit else { return text }
        var kept = String(text.prefix(limit))
        if let line = kept.lastIndex(of: "\n"), kept.distance(from: kept.startIndex, to: line) > limit / 2 {
            kept = String(kept[..<line])
        }
        return kept + "\n[Cut: showed \(kept.count.formatted()) of \(text.count.formatted()) characters. Ask for less: "
            + "`| where …`, `| select` the fields you need, `| take` fewer rows, or one item by its id.]"
    }
}
