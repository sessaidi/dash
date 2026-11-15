import DashKit
import DashKitTesting
import Foundation
import Testing
@testable import Dash

/// dash://ask links from outside the app.
@MainActor
struct AskLinkTests {
    @Test func parsesAndTrustsOnlyTheLocalToken() throws {
        let link = try #require(AskLink(URL(string: "dash://ask?q=Suggest%20an%20on-call%20layout&token=abc123&new=1")!))
        #expect(link.prompt == "Suggest an on-call layout" && link.newConversation)
        #expect(link.isTrusted(by: "abc123"))
        #expect(!link.isTrusted(by: "abc124") && !link.isTrusted(by: "") && !link.isTrusted(by: "abc1234"))
        #expect(AskLink(URL(string: "dash://ask?q=hi")!)?.isTrusted(by: "abc123") == false)
        #expect(AskLink(URL(string: "dash://ask?q=%20")!) == nil)
        #expect(AskLink(URL(string: "dash://open?q=hi")!) == nil)
        #expect(AskLink(URL(string: "https://ask?q=hi")!) == nil)
    }

    @Test func tokenIsPrivateAndStable() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dash-ask-\(UUID().uuidString)/ask-token")
        let token = AskLink.token(at: url)
        #expect(token.count == 64 && AskLink.token(at: url) == token)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func untrustedLinksAskBeforeSending() async throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "ask-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        let chat = ChatSession(host: host)
        let link = try #require(AskLink(URL(string: "dash://ask?q=delete%20my%20pages")!))
        // Nobody answers the prompt: the request stays unsent.
        let task = Task { await chat.open(link, token: "secret") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.transcript.isEmpty)
        host.permissionCenter.denyAll()
        await task.value
        #expect(chat.transcript.isEmpty)
    }
}
