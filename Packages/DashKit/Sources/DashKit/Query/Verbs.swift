import Foundation

/// A statement an extension adds to DashQL, so Dashii and agents can say `ticket follow LAF-123`
/// instead of calling a tool by name. Dash maps it to `tool`: the words after the action fill
/// `arguments` in order, and `key=value` options are passed as they are. It runs through the same
/// checks as calling the tool directly (approvals, read-only agents, no remote writes).
public struct DashQLVerb: Sendable, Equatable {
    /// The noun that starts it: "ticket", "pod", "monitor".
    public let keyword: String
    /// What to do: "follow", "logs", "show".
    public let action: String
    /// The tool it runs.
    public let tool: String
    /// Names, in order, for the words after the action (`ticket follow LAF-123` → key=LAF-123).
    public let arguments: [String]
    /// Inputs it always passes (`ticket unfollow` is `jira_follow` with follow=false); options can't override them.
    public let presets: [String: JSONValue]
    public let summary: String

    public init(_ keyword: String, _ action: String, tool: String, arguments: [String] = [], presets: [String: JSONValue] = [:], summary: String) {
        self.keyword = keyword.lowercased()
        self.action = action.lowercased()
        self.tool = tool
        self.arguments = arguments
        self.presets = presets
        self.summary = summary
    }

    /// How it's written, for help: `ticket follow <key> [key=value…]`.
    public var usage: String {
        ([keyword, action] + arguments.map { "<\($0)>" }).joined(separator: " ") + " [key=value…]"
    }
}
