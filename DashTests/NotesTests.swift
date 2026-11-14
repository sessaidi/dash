import DashKit
import DashKitTesting
import Foundation
import Testing
@testable import Dash

@MainActor
struct NotesTests {
    private func vault() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dash-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func createsSearchesLinksAndRenames() throws {
        let store = NotesStore(vault: vault())
        defer { try? FileManager.default.removeItem(at: store.vault) }
        let plan = try store.create(title: "Checkout plan", markdown: "Migrate payments. See [[Risks|the risks]] and [[Standup#Monday]].")
        let risks = try store.create(title: "Risks", markdown: "Card retries", folder: "Projects")
        let again = try store.create(title: "Risks", markdown: "", folder: "Projects")
        #expect(again.title == "Risks 2" && risks.folder == "Projects")
        #expect(store.search("payments").map(\.title) == ["Checkout plan"])
        #expect(NotesStore.links(in: store.read(plan)) == ["Risks", "Standup"])
        #expect(store.backlinks(to: risks).map(\.title) == ["Checkout plan"])
        #expect(NotesStore.linkified("See [[Risks|the risks]]") == "See [the risks](dash-note://Risks)")
        let renamed = try store.rename(plan, to: "Checkout: plan")
        #expect(renamed.title == "Checkout- plan")
        #expect(store.note(titled: "checkout- PLAN") != nil)
    }

    @Test func claudeToolsAndAIActions() async throws {
        let notes = NotesExtension(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!, vault: vault())
        defer { try? FileManager.default.removeItem(at: notes.store.vault) }
        let host = try TestHost([notes])
        host.start([notes])
        #expect(try await host.runTool("notes_create", ["title": "Standup", "markdown": "- shipped retries"]) == "Standup")
        _ = try await host.runTool("notes_append", ["title": "Standup", "markdown": "- next: rollout"])
        #expect(try await host.runTool("notes_read", ["title": "Standup"])?.string?.contains("next: rollout") == true)
        #expect(try await host.runTool("notes_search", ["query": "retries"])?.array?.count == 1)
        #expect(notes.tools.filter(\.requiresApproval).map(\.name) == ["notes_create", "notes_update", "notes_append"])
        // A second create with the same title is refused; update rewrites instead.
        await #expect(throws: (any Error).self) { try await host.runTool("notes_create", ["title": "Standup", "markdown": "again"]) }
        #expect(try await host.runTool("notes_update", ["title": "Standup", "markdown": "@TOC\n\n# Standup"]) == "updated")
        #expect(try await host.runTool("notes_read", ["title": "Standup"])?.string == "@TOC\n\n# Standup\n")
        // The writing tools teach the component syntax up front.
        let create = try #require(notes.tools.first { $0.name == "notes_create" })
        #expect(create.description.contains("@TOC") && create.description.contains("@Callout(style:") && create.description.contains("@Tabs"))

        host.testClaude.reply = "- [ ] Roll out retries (Ada)"
        let items = try await notes.run(.actionItems, title: "Standup", text: "Ada rolls out retries")
        #expect(items == "- [ ] Roll out retries (Ada)")
        let call = try #require(host.testClaude.calls.last)
        #expect(call.prompt.contains("# Standup") && call.source == "extension.notes/assist")
    }
}

struct NoteDocumentTests {
    private let source = """
    ---
    project: checkout
    owner: Ada
    ---
    # {{project}} plan

    - [ ] Ship retries
    - [x] Write tests

    @Callout(style: warning, title: "Freeze for {{project}}") {
      Until **Friday**.
    }

    @Columns {
      @Column { Left }
      @Column { Right }
    }

    > [!tip] Remember
    > Small PRs.

    @Toggle(label: "Shipped", checked: false)
    """

    @Test func parsesFrontmatterComponentsAndTasks() throws {
        let document = NoteDocument(source)
        #expect(document.values == ["project": "checkout", "owner": "Ada"])
        #expect(document.bodyLineOffset == 4)
        guard case .list(_, _, let items) = document.blocks[1] else { Issue.record("no list"); return }
        #expect(items.map(\.checked) == [false, true])
        #expect(items.map(\.line) == [3, 4])
        guard case .component(let callout) = document.blocks[2] else { Issue.record("no callout"); return }
        #expect(callout.name == "Callout")
        #expect(callout.arguments == ["style": "warning", "title": "Freeze for checkout"])
        #expect(callout.childSource.contains("Until **Friday**."))
        guard case .component(let columns) = document.blocks[3] else { Issue.record("no columns"); return }
        #expect(columns.children.count == 2)
        guard case .quote(let kind, let title, _) = document.blocks[4] else { Issue.record("no callout quote"); return }
        #expect(kind == "tip" && title == "Remember")
    }

    @Test func editsWriteBackIntoTheSource() {
        let document = NoteDocument(source)
        guard case .list(_, _, let items) = document.blocks[1] else { Issue.record("no list"); return }
        let ticked = NoteEdits.toggleTask(in: source, line: items[0].line + document.bodyLineOffset)
        #expect(ticked.contains("- [x] Ship retries"))
        guard case .component(let toggle) = document.blocks.last else { Issue.record("no toggle"); return }
        let switched = NoteEdits.setArgument(in: source, line: toggle.line + document.bodyLineOffset, name: "checked", value: "true")
        #expect(switched.contains(#"@Toggle(label: "Shipped", checked: true)"#))
        let added = NoteEdits.setArgument(in: "@Badge(text: Done)", line: 1, name: "tone", value: "success")
        #expect(added == "@Badge(text: Done, tone: success)")
        let quoted = NoteEdits.setArgument(in: "@Callout {", line: 1, name: "title", value: "Read me")
        #expect(quoted == #"@Callout(title: "Read me") {"#)
    }
}

@MainActor
struct NestedNotesTests {
    @Test func subNotesNestAndFollowRenamesAndDeletes() throws {
        let store = NotesStore(vault: FileManager.default.temporaryDirectory.appending(path: "dash-nest-\(UUID())", directoryHint: .isDirectory))
        defer { try? FileManager.default.removeItem(at: store.vault) }
        let plan = try store.create(title: "Plan")
        let step = try store.createChild(of: plan, title: "Step 1")
        _ = try store.createChild(of: step, title: "Detail")
        _ = try store.create(title: "Standup", folder: "Meetings")
        #expect(store.children(of: plan).map(\.title) == ["Step 1"])
        #expect(store.parent(of: step)?.title == "Plan")
        let tree = store.tree
        #expect(tree.map(\.title) == ["Plan", "Meetings"])
        #expect(tree[0].children?.first?.children?.first?.title == "Detail")
        #expect(tree[1].note == nil && tree[1].children?.first?.title == "Standup")
        let renamed = try store.rename(plan, to: "Roadmap")
        #expect(store.children(of: renamed).map(\.title) == ["Step 1"])
        try store.delete(renamed)
        #expect(store.notes.map(\.title) == ["Standup"])
    }

    @Test func outlineAndFormatting() {
        let source = "---\ntitle: x\n---\n# Intro\n```\n# not a heading\n```\n## Setup ##\n### Deep\n"
        #expect(NoteOutline.headings(in: source).map(\.title) == ["Intro", "Setup", "Deep"])
        #expect(NoteOutline.slug("Setup & run") == "h-setup---run")
        #expect(NoteSelectionAction.bold.format("hi") == "**hi**")
        #expect(NoteSelectionAction.code.format("a\nb") == "```\na\nb\n```")
        #expect(NoteSelectionAction.quote.format("a\nb") == "> a\n> b")
        #expect(NoteSelectionAction.link.format(" Plan ") == "[[Plan]]")
        #expect(NoteSelectionAction.rewrite.format("x") == nil)
    }
}

@MainActor
struct NoteDepthTests {
    @Test func subNotesNestAtMostFourDeep() throws {
        let vault = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        let store = NotesStore(vault: vault)
        var note = try store.create(title: "Plan")
        for level in 2...4 {
            note = try store.createChild(of: note, title: "Level \(level)")
            #expect(store.depth(note) == level)
        }
        #expect(!store.canHaveChildren(note))
        #expect(throws: (any Error).self) { try store.createChild(of: note) }
    }
}
