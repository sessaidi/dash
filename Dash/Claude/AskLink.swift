import DashKit
import Foundation
import Security

/// `dash://ask?q=…` sends a request to Dashii from outside the app (a script, a terminal, Claude
/// Code). Any app or web page can open a link, so a link runs straight away only when it carries
/// the token in `~/Library/Application Support/Dash/ask-token` (readable by the user alone);
/// otherwise Dash shows the request and asks first.
///
///     open "dash://ask?q=Suggest%20an%20on-call%20layout&token=$(cat ~/Library/Application\ Support/Dash/ask-token)"
///
/// `new=1` starts a new conversation first.
struct AskLink: Equatable {
    var prompt: String
    var token: String?
    var newConversation: Bool

    init?(_ url: URL) {
        guard url.scheme == "dash", url.host() == "ask",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let prompt = items.first(where: { $0.name == "q" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        self.prompt = String(prompt.prefix(8000))
        token = items.first { $0.name == "token" }?.value
        newConversation = ["1", "true", "yes"].contains(items.first { $0.name == "new" }?.value ?? "")
    }

    /// Whether the link carries this Mac's token (compared in constant time).
    func isTrusted(by expected: String) -> Bool {
        guard let token, !expected.isEmpty else { return false }
        let a = Array(token.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static var tokenURL: URL { URL.applicationSupportDirectory.appending(path: "Dash/ask-token") }

    /// The token, created on first use: 32 random bytes as hex, in a file only the user can read.
    static func token(at url: URL = tokenURL) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}

extension ChatSession {
    /// Handles a `dash://ask` link: runs it when trusted, else asks the user first.
    func open(_ link: AskLink, token: String = AskLink.token()) async {
        isPanelVisible = true
        if !link.isTrusted(by: token) {
            let approved = await host.permissions.ask(
                icon: "link", title: "Send this to \(host.persona.name)?",
                message: "An app or a web page opened a dash://ask link. Only send it if you started it.",
                details: [.init(title: "Request", text: link.prompt)], allowLabel: "Send", denyLabel: "Ignore")
            guard approved else { return }
        }
        if isRunning {
            notice("A dash://ask request arrived while \(host.persona.name) was answering; send it again when this answer is done.", isError: true)
            return
        }
        if link.newConversation { reset() }
        send(link.prompt)
    }
}
