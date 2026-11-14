import Foundation
import Testing
@testable import Dash

@MainActor
@Suite("Chat history")
struct ChatHistoryTests {
    @Test func conversationsReopenAndDelete() throws {
        let host = try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "chat-\(UUID())")!),
                                     extensions: ExtensionHost.builtInExtensions(), inMemory: true)
        let chat = ChatSession(host: host)
        let old = ChatConversation(title: "What's on my plate?")
        old.entries = [ChatEntry(id: "1", kind: .user("What's on my plate?")), ChatEntry(id: "2", kind: .tool(name: "list_widgets", input: "{}", result: "[]", isError: false)),
                       ChatEntry(id: "3", kind: .text("Two PRs to review."))]
        old.sessionID = "session-1"
        host.context.insert(old)
        try host.context.save()

        #expect(chat.conversations().map(\.title) == ["What's on my plate?"])
        chat.open(old)
        #expect(chat.transcript == old.entries && chat.conversationID == old.id)
        // Saving again updates the same conversation rather than adding one.
        chat.saveConversation()
        #expect(chat.conversations().count == 1)
        chat.reset()
        #expect(chat.transcript.isEmpty && chat.conversationID == nil)
        chat.delete(old)
        #expect(chat.conversations().isEmpty)
    }
}
