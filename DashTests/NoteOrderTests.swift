import Foundation
import Testing
@testable import Dash

@MainActor
@Suite("Note order")
struct NoteOrderTests {
    func store() -> NotesStore {
        NotesStore(vault: FileManager.default.temporaryDirectory.appending(path: "dash-order-\(UUID())", directoryHint: .isDirectory))
    }

    func titles(_ store: NotesStore) -> [String] { store.tree.map(\.title) }

    @Test func reorderPersistsAcrossReloads() throws {
        let store = store()
        let a = try store.create(title: "A")
        try store.create(title: "B")
        let c = try store.create(title: "C")
        #expect(titles(store) == ["A", "B", "C"])
        try store.move(c, .before, a)
        #expect(titles(store) == ["C", "A", "B"])
        try store.move(a, .after, store.note(titled: "B")!)
        #expect(titles(store) == ["C", "B", "A"])
        store.reload()
        #expect(titles(store) == ["C", "B", "A"])
        // New pages go after the arranged ones.
        try store.create(title: "0 first by name")
        #expect(titles(store) == ["C", "B", "A", "0 first by name"])
        store.resetOrder(of: "")
        #expect(titles(store) == ["0 first by name", "A", "B", "C"])
    }

    @Test func dropInsideMakesASubPage() throws {
        let store = store()
        let plan = try store.create(title: "Plan")
        let idea = try store.create(title: "Idea")
        try store.createChild(of: idea, title: "Detail")
        let moved = try store.move(idea, .inside, plan)
        #expect(moved.folder == "Plan")
        #expect(store.parent(of: moved)?.title == "Plan")
        // Its own sub-page came along.
        #expect(store.children(of: moved).map(\.title) == ["Detail"])
        #expect(titles(store) == ["Plan"])

        // And back out, before Plan.
        let out = try store.move(moved, .before, store.note(titled: "Plan")!)
        #expect(out.folder.isEmpty)
        #expect(titles(store) == ["Idea", "Plan"])
        #expect(store.children(of: out).map(\.title) == ["Detail"])
    }

    @Test func subPageOrderFollowsMovesAndRenames() throws {
        let store = store()
        let parent = try store.create(title: "Parent")
        try store.createChild(of: parent, title: "One")
        let two = try store.createChild(of: parent, title: "Two")
        try store.move(two, .before, store.note(titled: "One")!)
        #expect(store.children(of: parent).map(\.title) == ["Two", "One"])
        let renamed = try store.rename(parent, to: "Renamed")
        #expect(store.children(of: renamed).map(\.title) == ["Two", "One"])
        let holder = try store.create(title: "Holder")
        let nested = try store.move(renamed, .inside, holder)
        #expect(store.children(of: nested).map(\.title) == ["Two", "One"])
    }

    @Test func refusesCyclesDepthAndClashes() throws {
        let store = store()
        let top = try store.create(title: "Top")
        let child = try store.createChild(of: top, title: "Child")
        #expect(throws: (any Error).self) { try store.move(top, .inside, child) }

        // Four levels deep already: nothing more can go under the deepest.
        let l3 = try store.createChild(of: child, title: "L3")
        let l4 = try store.createChild(of: l3, title: "L4")
        let other = try store.create(title: "Other")
        #expect(throws: (any Error).self) { try store.move(other, .inside, l4) }
        // A page with a sub-page can't go where its sub-page would be level 5.
        try store.createChild(of: other, title: "Under")
        #expect(throws: (any Error).self) { try store.move(other, .inside, l3) }

        try store.create(title: "Child")
        #expect(throws: (any Error).self) { try store.move(store.notes.first { $0.title == "Child" && $0.folder.isEmpty }!, .inside, top) }
    }
}
