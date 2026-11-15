import DashKit
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import Dash

@MainActor
struct NotePDFTests {
    private func host() throws -> ExtensionHost {
        try ExtensionHost(settings: AppSettings(defaults: UserDefaults(suiteName: "dash-tests-\(UUID())")!),
                          extensions: ExtensionHost.builtInExtensions(), inMemory: true)
    }

    private let longNote: String = {
        var rows = (1...70).map { "| Service \($0) | owner\($0) | \($0 % 3 == 0 ? "degraded" : "ok") |" }.joined(separator: "\n")
        rows = "| Name | Owner | Status |\n|---|---|---|\n" + rows
        return """
        # Overview
        Intro paragraph about the migration.

        @Columns {
          @Column { Left side }
          @Column { Right side }
        }

        @Toggle(label: "Shipped", checked: true)

        @Ask(prompt: "anything")

        @Callout(style: note, frozen: hide) {
          Secret callout that must not print.
        }

        ## Services
        \(rows)

        ## After the table
        Closing words.
        """
    }()

    @Test func exportsPagesKeepingTablesWholeOrContinuedWithHeaders() throws {
        let host = try host()
        let url = FileManager.default.temporaryDirectory.appending(path: "dash-test-\(UUID()).pdf")
        defer { if ProcessInfo.processInfo.environment["DASH_PDF_OUT"] == nil { try? FileManager.default.removeItem(at: url) } }
        var options = NotePDFOptions()
        options.title = "Migration"
        options.author = "Ada"
        try NotePDFExporter(host: host, options: options).export([("Plan", longNote), ("Second", "# Hello\nShort note.")], to: url)
        if let out = ProcessInfo.processInfo.environment["DASH_PDF_OUT"] {
            try? FileManager.default.removeItem(atPath: out)
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: out))
        }
        let pdf = try #require(PDFDocument(url: url))
        // Cover, contents, at least two body pages for the long table, the second note, the end page.
        #expect(pdf.pageCount >= 6)
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        #expect(text.contains("Migration") && text.contains("Contents"))
        #expect(text.contains("Service 70") && text.contains("Closing words."))
        #expect(!text.contains("Secret callout"))
        // The table continues on a later page with its header row again.
        let headerPages = (0..<pdf.pageCount).filter { pdf.page(at: $0)?.string?.contains("Owner") == true }
        #expect(headerPages.count >= 2)
        // No page holds the table's header without at least one row under it.
        for index in headerPages { #expect(pdf.page(at: index)?.string?.contains("Service") == true) }
    }

    /// Several big tables: 200 rows, a wide one, and one whose cells wrap over many lines.
    @Test func bigTablesSplitWithHeadersOnEveryPage() throws {
        let host = try host()
        let long = (1...200).map { "| \($0) | svc-\($0) | \($0 % 7 == 0 ? "**degraded**" : "ok") | \($0 * 13 % 997) ms |" }.joined(separator: "\n")
        let wide = (1...40).map { row in "| " + (1...8).map { "r\(row)c\($0)" }.joined(separator: " | ") + " |" }.joined(separator: "\n")
        let wordy = (1...25).map { "| Item \($0) | " + String(repeating: "A long explanation that wraps over several lines. ", count: $0 % 5 + 1) + " | done |" }.joined(separator: "\n")
        let note = """
        # Big tables
        @TOC

        ## Latency
        | # | Service | Status | p99 |
        |---|---|---|---|
        \(long)

        ## Wide
        | A | B | C | D | E | F | G | H |
        |---|---|---|---|---|---|---|---|
        \(wide)

        ## Wordy
        | Item | Notes | State |
        |---|---|---|
        \(wordy)

        The end.
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "dash-big-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try NotePDFExporter(host: host, options: NotePDFOptions()).export([("Big tables", note)], to: url)
        if let out = ProcessInfo.processInfo.environment["DASH_PDF_BIG"] {
            try? FileManager.default.removeItem(atPath: out)
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: out))
        }
        let pdf = try #require(PDFDocument(url: url))
        let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        let text = pages.joined(separator: "\n")
        for needle in ["svc-1 ", "svc-200", "r40c8", "Item 25", "The end."] { #expect(text.contains(needle), "missing \(needle)") }
        // Each page with latency rows also shows that table's header.
        for page in pages where page.contains("svc-") { #expect(page.contains("p99")) }
        for page in pages where page.contains("r") && page.range(of: #"r\d+c1"#, options: .regularExpression) != nil { #expect(page.contains("H")) }
        #expect(pages.filter { $0.contains("p99") }.count >= 4)
        // Rows are never sliced: a wrapped row's first cell and its last cell share a page,
        // and every wordy row prints exactly once.
        for page in pages where page.contains("Item ") {
            let items = page.components(separatedBy: "Item ").count - 2  // minus text before, minus the header "Item"
            let states = page.components(separatedBy: "done").count - 1
            #expect(items == states, "page cuts a row: \(items) rows, \(states) last cells")
        }
        #expect((1...25).allSatisfy { n in pages.filter { $0.range(of: "Item \(n)\\b", options: .regularExpression) != nil }.count == 1 })
    }

    @Test func headingsStayWithWhatFollows() throws {
        let host = try host()
        let exporter = NotePDFExporter(host: host, options: NotePDFOptions())
        let tall = NotePDFExporter.Piece(view: AnyView(EmptyView()), height: 600, keepWithNext: false)
        let heading = NotePDFExporter.Piece(view: AnyView(EmptyView()), height: 30, keepWithNext: true)
        let body = NotePDFExporter.Piece(view: AnyView(EmptyView()), height: 120, keepWithNext: false)
        let pages = exporter.paginate([tall, heading, body], header: "x")
        // The heading would fit after the tall block, but its paragraph wouldn't: both move.
        #expect(pages.count == 2)
        #expect(pages[1].pieces.count == 2)
    }
}
