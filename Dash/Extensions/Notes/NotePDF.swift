import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// How a PDF export looks.
struct NotePDFOptions {
    enum PageSize: String, CaseIterable, Identifiable {
        case a4, letter
        var id: String { rawValue }
        var title: String { self == .a4 ? "A4" : "US Letter" }
        var size: CGSize { self == .a4 ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }
    }

    var pageSize = PageSize.a4
    var title = ""
    var subtitle = ""
    var author = ""
    var cover = true
    /// A contents page listing the notes with their page numbers (when there's more than one).
    var contents = true
    var endPage = true
    var margin: CGFloat = 54
}

/// Lays notes out on pages and writes a vector PDF.
///
/// Every block is measured at the page width and placed whole: a block that doesn't fit the
/// rest of a page moves to the next, and a heading never ends a page (it moves with what follows).
/// Only a block taller than a whole page is split: tables by rows (each part repeats the header
/// row), lists by items, code by lines; anything else is clipped across pages as a last resort.
@MainActor
struct NotePDFExporter {
    let host: ExtensionHost
    var options: NotePDFOptions

    private var page: CGSize { options.pageSize.size }
    private var contentWidth: CGFloat { page.width - options.margin * 2 }
    /// Room for the running header and the page number.
    private var bodyTop: CGFloat { options.margin + 22 }
    private var bodyHeight: CGFloat { page.height - bodyTop - options.margin - 24 }

    /// One thing to draw at a size measured for the page width.
    struct Piece {
        let view: AnyView
        let height: CGFloat
        let keepWithNext: Bool
        /// For clipped pieces: the part of the view to show.
        var clipOffset: CGFloat = 0
        /// For a block taller than a page (tables, lists, code): the largest first part that
        /// fits `available`, and the rest (nil when even the smallest part doesn't fit).
        var split: ((_ available: CGFloat) -> (first: Piece, rest: Piece?)?)?
        /// The smallest first part (e.g. a table's header and one row), for keeping headings with it.
        var minimumHeight: CGFloat?
    }

    struct Page {
        var pieces: [(piece: Piece, y: CGFloat)] = []
        var header: String
        var kind: Kind = .body
        enum Kind { case cover, contents, body, end }
    }

    // MARK: Export

    /// Writes `notes` (in order) to `url`.
    func export(_ notes: [(title: String, source: String)], to url: URL) throws {
        var bodyPages: [Page] = []
        var starts: [(title: String, page: Int)] = []
        for note in notes {
            starts.append((note.title, bodyPages.count))
            bodyPages += paginate(pieces(for: note), header: note.title)
        }
        var pages: [Page] = []
        if options.cover { pages.append(Page(header: "", kind: .cover)) }
        let contentsPages = options.contents && notes.count > 1 ? max(1, Int(ceil(Double(notes.count) / 28))) : 0
        for _ in 0..<contentsPages { pages.append(Page(header: "", kind: .contents)) }
        let offset = pages.count
        pages += bodyPages
        if options.endPage { pages.append(Page(header: "", kind: .end)) }
        let entries = starts.map { (title: $0.title, page: $0.page + offset + 1) }
        try write(pages, entries: entries, to: url)
    }

    // MARK: Pieces

    private func pieces(for note: (title: String, source: String)) -> [Piece] {
        let document = NoteDocument(note.source)
        let context = NoteRenderContext(host: host, source: note.source, lineOffset: document.bodyLineOffset,
                                        noteTitle: note.title, depth: 0, printing: true,
                                        printSize: CGSize(width: contentWidth, height: bodyHeight - 40), onChange: nil)
        // The note's title, unless the note already opens with it as a heading.
        var result: [Piece] = []
        if case .heading(_, let text)? = document.blocks.first,
           String(text.characters).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(note.title) == .orderedSame {
        } else {
            result.append(piece(Text(note.title).font(.system(size: 26, weight: .bold)).padding(.bottom, 6), keepWithNext: true))
        }
        for block in document.blocks {
            let isHeading: Bool = { if case .heading = block { return true }; return false }()
            let whole = piece(NoteBlockView(block: block, context: context), keepWithNext: isHeading)
            result.append(whole.height <= bodyHeight ? whole : splittable(block, context: context, whole: whole))
        }
        return result
    }

    private func piece(_ view: some View, keepWithNext: Bool = false) -> Piece {
        let wrapped = AnyView(printable(view))
        return Piece(view: wrapped, height: measure(wrapped), keepWithNext: keepWithNext)
    }

    /// Light, page-width, with the host in the environment (components need it).
    private func printable(_ view: some View) -> some View {
        view
            .frame(width: contentWidth, alignment: .leading)
            .environment(host)
            .environment(host.settings)
            .environment(\.colorScheme, .light)
            .foregroundStyle(.black)
            .tint(Color(red: 0.15, green: 0.35, blue: 0.85))
    }

    private func measure(_ view: AnyView) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
        var height: CGFloat = 0
        renderer.render { size, _ in height = size.height }
        return ceil(height) + 8
    }

    /// A block taller than a page, made splittable: tables by rows (every part repeats the
    /// header row), lists by items, code by lines; anything else is shown a page at a time.
    private func splittable(_ block: NoteBlock, context: NoteRenderContext, whole: Piece) -> Piece {
        switch block {
        case .table(let header, let rows):
            return parts(count: rows.count, whole: whole) { range in
                .table(header: header, rows: Array(rows[range]))
            } context: { context }
        case .list(let ordered, let start, let items) where items.count > 1:
            return parts(count: items.count, whole: whole) { range in
                .list(ordered: ordered, start: start + range.lowerBound, items: Array(items[range]))
            } context: { context }
        case .code(let language, let text):
            let lines = text.components(separatedBy: "\n")
            return parts(count: lines.count, whole: whole) { range in
                .code(language: range.lowerBound == 0 ? language : nil, text: lines[range].joined(separator: "\n"))
            } context: { context }
        default:
            // Last resort: the same drawing, a page-sized slice at a time.
            var piece = whole
            piece.split = { available in
                guard available >= 60 else { return nil }
                let first = Piece(view: whole.view, height: available, keepWithNext: false, clipOffset: whole.clipOffset)
                var rest = whole
                rest = Piece(view: whole.view, height: whole.height - available, keepWithNext: false, clipOffset: whole.clipOffset + available)
                return (first, rest.height > 0 ? rest : nil)
            }
            piece.minimumHeight = 60
            return piece
        }
    }

    /// A splittable piece over `count` items (rows, list items, lines): each split takes as many
    /// items as fit (found by bisection), and the rest stays splittable.
    private func parts(count: Int, whole: Piece, offset: Int = 0, make: @escaping (Range<Int>) -> NoteBlock,
                       context: @escaping () -> NoteRenderContext) -> Piece {
        var piece = whole
        let render = { (range: Range<Int>) in self.piece(NoteBlockView(block: make(range), context: context())) }
        piece.minimumHeight = render(offset..<min(offset + 1, offset + count)).height
        piece.split = { available in
            // Largest k with items[offset..<offset+k] fitting.
            var low = 0, high = count
            var best: Piece?
            while low < high {
                let middle = (low + high + 1) / 2
                let candidate = render(offset..<(offset + middle))
                if candidate.height <= available { low = middle; best = candidate } else { high = middle - 1 }
            }
            guard low > 0, let first = best else { return nil }
            guard low < count else { return (first, nil) }
            let remaining = count - low
            let restWhole = render((offset + low)..<(offset + count))
            let rest = restWhole.height <= bodyHeight
                ? restWhole
                : parts(count: remaining, whole: restWhole, offset: offset + low, make: make, context: context)
            return (first, rest)
        }
        return piece
    }

    // MARK: Pagination

    func paginate(_ pieces: [Piece], header: String) -> [Page] {
        var pages = [Page(header: header)]
        var y: CGFloat = 0
        var queue = pieces
        var index = 0
        func newPage() {
            pages.append(Page(header: header))
            y = 0
        }
        while index < queue.count {
            let piece = queue[index]
            // Keep a heading with the next block, or with the smallest part of a splittable one.
            var needed = piece.height
            if piece.keepWithNext, index + 1 < queue.count {
                let next = queue[index + 1]
                needed += next.split != nil && next.height > bodyHeight ? (next.minimumHeight ?? next.height) : next.height
            }
            let remaining = bodyHeight - y
            if piece.height <= remaining, needed <= remaining || y == 0 {
                pages[pages.count - 1].pieces.append((piece, y))
                y += piece.height
                index += 1
            } else if piece.height > bodyHeight, let split = piece.split, let (first, rest) = split(remaining) {
                // Too tall for any page: fill the rest of this one, continue on the next.
                pages[pages.count - 1].pieces.append((first, y))
                queue.remove(at: index)
                if let rest { queue.insert(rest, at: index) }
                newPage()
            } else if y > 0 {
                newPage()
            } else {
                // Taller than a page and can't split: place it anyway (it's clipped).
                pages[pages.count - 1].pieces.append((piece, y))
                y += piece.height
                index += 1
            }
        }
        return pages
    }

    // MARK: Drawing

    private func write(_ pages: [Page], entries: [(title: String, page: Int)], to url: URL) throws {
        var box = CGRect(origin: .zero, size: page)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: options.title,
                                                                 kCGPDFContextCreator as String: "Dash"] as CFDictionary) else {
            throw ToolError("Couldn't create the PDF.")
        }
        var contentsDrawn = 0
        for (number, current) in pages.enumerated() {
            pdf.beginPDFPage(nil)
            switch current.kind {
            case .cover:
                draw(AnyView(cover), at: CGPoint(x: 0, y: 0), size: page, in: pdf)
            case .end:
                draw(AnyView(endPage(pages: pages.count)), at: .zero, size: page, in: pdf)
            case .contents:
                let slice = Array(entries.dropFirst(contentsDrawn * 28).prefix(28))
                draw(AnyView(printable(contents(slice, first: contentsDrawn == 0))), at: CGPoint(x: options.margin, y: options.margin),
                     size: CGSize(width: contentWidth, height: page.height - options.margin * 2), in: pdf)
                contentsDrawn += 1
            case .body:
                draw(AnyView(Text(current.header).font(.system(size: 9)).foregroundStyle(.gray).frame(width: contentWidth, alignment: .leading)),
                     at: CGPoint(x: options.margin, y: options.margin), size: CGSize(width: contentWidth, height: 14), in: pdf)
                for (piece, y) in current.pieces {
                    draw(piece, at: CGPoint(x: options.margin, y: bodyTop + y), in: pdf)
                }
            }
            if current.kind != .cover {
                draw(AnyView(Text("\(number + 1) / \(pages.count)").font(.system(size: 9)).foregroundStyle(.gray)
                    .frame(width: contentWidth, alignment: .center)),
                     at: CGPoint(x: options.margin, y: page.height - options.margin), size: CGSize(width: contentWidth, height: 14), in: pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    /// Draws a piece with its top-left corner at `origin` (page coordinates, y down).
    private func draw(_ piece: Piece, at origin: CGPoint, in pdf: CGContext) {
        let renderer = ImageRenderer(content: piece.view)
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
        renderer.render { size, render in
            pdf.saveGState()
            // Clip to the piece's slice (clipped pieces show part of a taller drawing).
            let top = page.height - origin.y
            pdf.clip(to: CGRect(x: origin.x - 2, y: top - piece.height, width: size.width + 4, height: piece.height))
            pdf.translateBy(x: origin.x, y: top - size.height + piece.clipOffset)
            render(pdf)
            pdf.restoreGState()
        }
    }

    private func draw(_ view: AnyView, at origin: CGPoint, size: CGSize, in pdf: CGContext) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        renderer.render { rendered, render in
            pdf.saveGState()
            pdf.translateBy(x: origin.x, y: page.height - origin.y - rendered.height)
            render(pdf)
            pdf.restoreGState()
        }
    }

    // MARK: Cover, contents, end

    private var cover: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            LinearGradient(colors: [Color(red: 0.45, green: 0.3, blue: 0.95), Color(red: 0.13, green: 0.75, blue: 0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: page.height * 0.42)
            VStack(alignment: .leading, spacing: 14) {
                Spacer().frame(height: page.height * 0.42 - 140)
                Text(options.title).font(.system(size: 38, weight: .bold)).foregroundStyle(.white).lineLimit(3)
                if !options.subtitle.isEmpty { Text(options.subtitle).font(.system(size: 17)).foregroundStyle(.white.opacity(0.9)) }
                Spacer().frame(height: 60)
                if !options.author.isEmpty { Text(options.author).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black) }
                Text(Date.now.formatted(date: .long, time: .omitted)).font(.system(size: 13)).foregroundStyle(.gray)
                Spacer()
                HStack(spacing: 8) {
                    DashiiAvatar().frame(width: 30, height: 26)
                    Text("Made with Dash").font(.system(size: 11)).foregroundStyle(.gray)
                }
            }
            .padding(options.margin)
        }
        .frame(width: page.width, height: page.height)
        .environment(host)
        .environment(\.colorScheme, .light)
    }

    private func contents(_ entries: [(title: String, page: Int)], first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if first { Text("Contents").font(.system(size: 24, weight: .bold)).padding(.bottom, 12) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(.system(size: 13))
                    Text(String(repeating: ".", count: 80)).font(.system(size: 13)).foregroundStyle(.gray.opacity(0.6)).lineLimit(1)
                    Text("\(entry.page)").font(.system(size: 13).monospacedDigit())
                }
            }
            Spacer()
        }
    }

    private func endPage(pages: Int) -> some View {
        VStack(spacing: 10) {
            Spacer()
            DashiiAvatar().frame(width: 56, height: 48)
            Text(options.title).font(.system(size: 16, weight: .semibold))
            Text("\(pages) pages · exported \(Date.now.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(.gray)
            Text("Made with Dash").font(.system(size: 11)).foregroundStyle(.gray)
            Spacer()
        }
        .frame(width: page.width, height: page.height)
        .background(Color.white)
        .environment(host)
        .environment(\.colorScheme, .light)
    }
}
