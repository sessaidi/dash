import DashKit
import Foundation

/// Starting a long conversation over with a summary: every message re-reads the whole
/// conversation, so past `threshold` tokens of context Dash offers to continue in a new one that
/// starts from a handoff summary. The summary is written in the running session when there is
/// one (it sees everything, cached), else from the messages. The old conversation stays in History.
enum FreshStart {
    /// Context (tokens) past which the chat suggests a fresh start.
    static let threshold = 100_000
    /// Characters of the old conversation the summary is written from (the most recent kept).
    static let sourceLimit = 160_000

    static let system = """
        You write the handoff of a long conversation between the user and Dashii (their dashboard's \
        assistant), so a new conversation can continue it without the old one. Write Markdown with these \
        sections, leaving out empty ones: Goal, Where we are, Decisions, Facts and ids (exact ticket keys, PR \
        numbers, repositories, files, symbols, URLs, names, numbers), The user's preferences and corrections, \
        Open questions, Next step. Keep every id and number exactly. Don't add anything that wasn't said. \
        Tool results aren't kept: say which ones the next conversation should fetch again if it needs them. \
        Dense bullets, no padding: as long as needed and no longer (usually under 800 words).
        """

    /// Asked inside the running session, which already holds the whole conversation (tool results
    /// and reasoning included) in its cache: the best summary, for a tenth of the input price.
    static let inSession = """
        Stop the current task. Write the handoff of this conversation so a new conversation can continue \
        it without this one. Don't call any tool: answer with the handoff only. \
        Markdown sections, leaving out empty ones: Goal, Where we are, Decisions, Facts and ids (exact ticket \
        keys, PR numbers, repositories, files, symbols, URLs, names, numbers), Findings from tool results (the \
        values the next conversation needs, compactly; say what to fetch again for the rest), The user's \
        preferences and corrections, Open questions, Next step. Keep every id and number exactly; add nothing \
        that wasn't established. Dense bullets, no padding: as long as needed and no longer (usually under 800 words).
        """

    /// The conversation as text: messages in full, tool calls with the start of their input and
    /// result (the results themselves are in Dash's database, to fetch again).
    static func source(_ entries: [ChatEntry]) -> String {
        let lines: [String] = entries.compactMap { entry in
            switch entry.kind {
            case .user(let text): "User: \(text)"
            case .text(let text): "Dashii: \(text)"
            case .tool(let name, let input, let result, let isError):
                "[tool \(name)\(isError ? ", failed" : "")] \(input.prefix(300))" + (result.map { "\n→ \($0.prefix(600))" } ?? "")
            case .notice(let text, _): "[\(text)]"
            case .thinking, .choices, .layouts: nil
            }
        }
        var text = lines.joined(separator: "\n\n")
        if text.count > sourceLimit {
            // The first question says what it was about; the end is where it stands.
            let first = lines.first ?? ""
            text = first.prefix(4_000) + "\n\n[… earlier part left out …]\n\n" + text.suffix(sourceLimit - 4_000)
        }
        return text
    }

    /// The first message of the new conversation carries the summary once.
    static func carryOver(_ summary: String, title: String) -> String {
        "<earlier-conversation title=\"\(title)\">\nThis conversation continues an earlier one, summarised here. "
            + "Its tool results weren't kept: fetch again what you need.\n\n\(summary)\n</earlier-conversation>"
    }
}
