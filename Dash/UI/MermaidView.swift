import SwiftUI

/// A Mermaid flowchart (`flowchart LR` / `graph TD`) parsed for drawing natively: nodes with their
/// shapes, edges with labels and styles, subgraphs. Other diagram kinds aren't handled (nil).
struct MermaidGraph: Equatable {
    enum Direction { case leftToRight, rightToLeft, topToBottom, bottomToTop }
    enum Shape: Equatable { case box, rounded, stadium, cylinder, circle, diamond, subroutine, flag }
    enum Line: Equatable { case solid, dotted, thick, plain }

    struct Node: Equatable, Identifiable {
        let id: String
        var label: String
        var shape: Shape
        var group: String?
    }

    struct Edge: Equatable {
        let from: String
        let to: String
        var label: String?
        var line: Line
        var arrow: Bool
    }

    struct Group: Equatable, Identifiable {
        let id: String
        var title: String
    }

    var direction: Direction
    var nodes: [Node] = []
    var edges: [Edge] = []
    var groups: [Group] = []

    var isHorizontal: Bool { direction == .leftToRight || direction == .rightToLeft }

    // MARK: Parsing

    static func parse(_ text: String) -> MermaidGraph? {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return nil }
        let words = header.split(separator: " ")
        guard let kind = words.first, kind == "flowchart" || kind == "graph" else { return nil }
        var graph = MermaidGraph(direction: .topToBottom)
        switch words.dropFirst().first.map(String.init)?.uppercased() {
        case "LR": graph.direction = .leftToRight
        case "RL": graph.direction = .rightToLeft
        case "BT": graph.direction = .bottomToTop
        default: graph.direction = .topToBottom
        }
        lines.removeFirst()

        var stack: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("subgraph") {
                var rest = line.dropFirst("subgraph".count).trimmingCharacters(in: .whitespaces)
                var title = rest
                if let open = rest.firstIndex(of: "["), rest.hasSuffix("]") {
                    title = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
                    rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
                }
                let id = rest.isEmpty ? "group\(graph.groups.count)" : rest
                graph.groups.append(Group(id: id, title: unquote(title)))
                stack.append(id)
                continue
            }
            if lower == "end" { _ = stack.popLast(); continue }
            if ["classdef", "class ", "style ", "linkstyle", "click ", "direction "].contains(where: { lower.hasPrefix($0) }) { continue }
            graph.read(statement: line, group: stack.last)
        }
        return graph.nodes.isEmpty ? nil : graph
    }

    /// A node list or a chain: `A[x] --> B & C -- label --> D`.
    private mutating func read(statement: String, group: String?) {
        var rest = Substring(statement)
        var previous: [String] = []
        var pending: (label: String?, line: Line, arrow: Bool)?
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " }
            if let link = Self.link(&rest) {
                pending = link
                continue
            }
            var ids: [String] = []
            repeat {
                rest = rest.drop { $0 == " " || $0 == "&" }
                guard let id = node(&rest, group: group) else { return }
                ids.append(id)
                rest = rest.drop { $0 == " " }
            } while rest.first == "&"
            if let link = pending {
                for from in previous { for to in ids { edges.append(Edge(from: from, to: to, label: link.label, line: link.line, arrow: link.arrow)) } }
                pending = nil
            }
            previous = ids
            rest = rest.drop { $0 == ";" || $0 == " " }
        }
    }

    /// `-->`, `---`, `-.->`, `==>`, `-- text -->`, `-->|text|`.
    private static func link(_ rest: inout Substring) -> (label: String?, line: Line, arrow: Bool)? {
        let patterns: [(String, Line, Bool)] = [("-.->", .dotted, true), ("-.-", .dotted, false), ("==>", .thick, true), ("===", .thick, false),
                                                ("-->", .solid, true), ("---", .plain, false)]
        for (token, line, arrow) in patterns where rest.hasPrefix(token) {
            rest = rest.dropFirst(token.count).drop { $0 == ">" || $0 == "-" }
            var label: String?
            if rest.first == "|", let end = rest.dropFirst().firstIndex(of: "|") {
                label = String(rest[rest.index(after: rest.startIndex)..<end])
                rest = rest[rest.index(after: end)...]
            }
            return (label.map(unquote), line, arrow)
        }
        // `-- text -->` / `== text ==>` / `-. text .->`
        for (open, close, line) in [("-- ", "-->", Line.solid), ("== ", "==>", .thick), ("-. ", ".->", .dotted)] where rest.hasPrefix(open) {
            let body = rest.dropFirst(open.count)
            guard let range = body.range(of: close) else { return nil }
            let label = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            rest = body[range.upperBound...]
            return (unquote(label), line, true)
        }
        return nil
    }

    /// An id, optionally with a shape and label: `A`, `A[text]`, `A[(db)]`, `A((c))`, `A{d}`…
    private mutating func node(_ rest: inout Substring, group: String?) -> String? {
        // Ids may contain "-" (page-manager) but a link starts with "--", "-." or "->".
        var id = ""
        var index = rest.startIndex
        while index < rest.endIndex {
            let character = rest[index]
            let next = rest.index(after: index) < rest.endIndex ? rest[rest.index(after: index)] : " "
            guard character.isLetter || character.isNumber || character == "_" || (character == "-" && !"-.>".contains(next)) else { break }
            id.append(character)
            index = rest.index(after: index)
        }
        guard !id.isEmpty else { return nil }
        rest = rest.dropFirst(id.count)
        let shapes: [(String, String, Shape)] = [("([", "])", .stadium), ("[(", ")]", .cylinder), ("((", "))", .circle), ("[[", "]]", .subroutine),
                                                 ("[", "]", .box), ("(", ")", .rounded), ("{", "}", .diamond), (">", "]", .flag)]
        var label: String?
        var shape = Shape.box
        for (open, close, kind) in shapes where rest.hasPrefix(open) {
            let body = rest.dropFirst(open.count)
            guard let range = body.range(of: close) else { break }
            label = Self.unquote(String(body[..<range.lowerBound]))
            shape = kind
            rest = body[range.upperBound...]
            break
        }
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            if let label { nodes[index].label = label; nodes[index].shape = shape }
            if nodes[index].group == nil { nodes[index].group = group }
        } else {
            nodes.append(Node(id: id, label: label ?? id, shape: shape, group: group))
        }
        return id
    }

    private static func unquote(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") { text = String(text.dropFirst().dropLast()) }
        return text.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
    }

    // MARK: Layout

    struct Layout {
        var frames: [String: CGRect]
        var groupFrames: [String: CGRect]
        var size: CGSize
    }

    /// Layered layout: ranks by longest path from the sources, order in a rank by the average
    /// position of neighbours (a few sweeps), members of a subgraph kept together.
    func layout(size measure: (Node) -> CGSize) -> Layout {
        let ids = nodes.map(\.id)
        var rank: [String: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        // Longest path, cycle-safe: relax at most nodes.count times.
        for _ in 0..<max(ids.count, 1) {
            var changed = false
            for edge in edges where edge.from != edge.to {
                let next = (rank[edge.from] ?? 0) + 1
                if next > rank[edge.to] ?? 0, next < ids.count { rank[edge.to] = next; changed = true }
            }
            if !changed { break }
        }
        let maxRank = rank.values.max() ?? 0
        var layers: [[String]] = (0...maxRank).map { level in ids.filter { rank[$0] == level } }
        let groupIndex: [String: Int] = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        func groupKey(_ id: String) -> Int { nodes.first { $0.id == id }?.group.flatMap { groupIndex[$0] } ?? -1 }

        for sweep in 0..<4 {
            let down = sweep % 2 == 0
            for level in (down ? Array(1...max(maxRank, 1)) : Array((0..<maxRank).reversed())) where level <= maxRank {
                let neighbourLayer = layers[down ? level - 1 : level + 1]
                let position = Dictionary(uniqueKeysWithValues: neighbourLayer.enumerated().map { ($1, Double($0)) })
                func centre(_ id: String) -> Double {
                    let linked = edges.compactMap { edge -> Double? in
                        if down, edge.to == id { return position[edge.from] }
                        if !down, edge.from == id { return position[edge.to] }
                        return nil
                    }
                    return linked.isEmpty ? Double(layers[level].firstIndex(of: id) ?? 0) : linked.reduce(0, +) / Double(linked.count)
                }
                let keys = Dictionary(uniqueKeysWithValues: layers[level].map { ($0, (groupKey($0), centre($0))) })
                layers[level].sort { keys[$0]! < keys[$1]! }
            }
        }

        let sizes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, measure($0)) })
        let gapAcross: CGFloat = 22, gapAlong: CGFloat = 70, margin: CGFloat = 40
        var frames: [String: CGRect] = [:]
        var along: CGFloat = margin
        var extentAcross: CGFloat = 0
        let layerAcross = layers.map { layer in layer.reduce(0) { $0 + (isHorizontal ? sizes[$1]!.height : sizes[$1]!.width) } + gapAcross * CGFloat(max(layer.count - 1, 0)) }
        let widest = layerAcross.max() ?? 0
        for (level, layer) in layers.enumerated() {
            let thickness = layer.map { isHorizontal ? sizes[$0]!.width : sizes[$0]!.height }.max() ?? 0
            var across = margin + (widest - layerAcross[level]) / 2
            for id in layer {
                let size = sizes[id]!
                let origin = isHorizontal
                    ? CGPoint(x: along + (thickness - size.width) / 2, y: across)
                    : CGPoint(x: across, y: along + (thickness - size.height) / 2)
                frames[id] = CGRect(origin: origin, size: size)
                across += (isHorizontal ? size.height : size.width) + gapAcross
            }
            extentAcross = max(extentAcross, across)
            along += thickness + gapAlong
        }
        var total = isHorizontal ? CGSize(width: along - gapAlong + margin, height: extentAcross + margin)
                                 : CGSize(width: extentAcross + margin, height: along - gapAlong + margin)
        // Reverse directions mirror the drawing.
        if direction == .rightToLeft || direction == .bottomToTop {
            for (id, frame) in frames {
                frames[id] = direction == .rightToLeft
                    ? CGRect(x: total.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
                    : CGRect(x: frame.minX, y: total.height - frame.maxY, width: frame.width, height: frame.height)
            }
        }
        var groupFrames: [String: CGRect] = [:]
        for group in groups {
            let members = nodes.filter { $0.group == group.id }.compactMap { frames[$0.id] }
            guard let first = members.first else { continue }
            // Room around the members, and above them for the title.
            let bounds = members.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -12, dy: -12)
            groupFrames[group.id] = CGRect(x: bounds.minX, y: bounds.minY - 18, width: bounds.width, height: bounds.height + 18)
        }
        for frame in groupFrames.values { total.width = max(total.width, frame.maxX + 8); total.height = max(total.height, frame.maxY + 8) }
        return Layout(frames: frames, groupFrames: groupFrames, size: total)
    }
}

/// Draws a `MermaidGraph` with SwiftUI: shapes, labels, curved edges with arrows, subgraph boxes.
/// Scrolls when wider than the note.
struct MermaidView: View {
    let graph: MermaidGraph
    @Environment(\.colorScheme) private var colorScheme

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var body: some View {
        let layout = graph.layout(size: Self.size)
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                ForEach(graph.groups) { group in
                    if let frame = layout.groupFrames[group.id] {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .overlay(alignment: .topLeading) { Text(group.title).font(.caption.bold()).foregroundStyle(.secondary).padding(6) }
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let from = layout.frames[edge.from], let to = layout.frames[edge.to] else { continue }
                        draw(edge, from: from, to: to, in: &context)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
                    if let label = edge.label, let from = layout.frames[edge.from], let to = layout.frames[edge.to] {
                        let middle = CGPoint(x: (from.midX + to.midX) / 2, y: (from.midY + to.midY) / 2)
                        Text(label).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.background, in: .rect(cornerRadius: 4))
                            .fixedSize()
                            .position(middle)
                    }
                }
                ForEach(graph.nodes) { node in
                    if let frame = layout.frames[node.id] {
                        NodeView(node: node)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
    }

    /// Room for a node's label, wrapped at about 26 characters.
    static func size(_ node: MermaidGraph.Node) -> CGSize {
        let maxWidth: CGFloat = 190
        let text = NSAttributedString(string: node.label, attributes: [.font: font])
        let bounds = text.boundingRect(with: CGSize(width: maxWidth, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
        var size = CGSize(width: ceil(bounds.width) + 26, height: ceil(bounds.height) + 18)
        switch node.shape {
        case .diamond: size = CGSize(width: size.width * 1.5, height: max(size.height * 1.6, 54))
        case .circle: let side = max(size.width, size.height); size = CGSize(width: side, height: side)
        case .cylinder: size.height += 12
        default: break
        }
        return CGSize(width: max(size.width, 70), height: max(size.height, 34))
    }

    private func draw(_ edge: MermaidGraph.Edge, from: CGRect, to: CGRect, in context: inout GraphicsContext) {
        let horizontal = graph.isHorizontal
        let forward = horizontal ? to.midX >= from.midX : to.midY >= from.midY
        let start: CGPoint, end: CGPoint
        if horizontal {
            start = CGPoint(x: forward ? from.maxX : from.minX, y: from.midY)
            end = CGPoint(x: forward ? to.minX : to.maxX, y: to.midY)
        } else {
            start = CGPoint(x: from.midX, y: forward ? from.maxY : from.minY)
            end = CGPoint(x: to.midX, y: forward ? to.minY : to.maxY)
        }
        let bend = max(abs(horizontal ? end.x - start.x : end.y - start.y) / 2, 20)
        let sign: CGFloat = forward ? 1 : -1
        var path = Path()
        path.move(to: start)
        if horizontal {
            path.addCurve(to: end, control1: CGPoint(x: start.x + bend * sign, y: start.y), control2: CGPoint(x: end.x - bend * sign, y: end.y))
        } else {
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend * sign), control2: CGPoint(x: end.x, y: end.y - bend * sign))
        }
        let color = Color.secondary
        let style: StrokeStyle
        switch edge.line {
        case .dotted: style = StrokeStyle(lineWidth: 1.4, dash: [4, 4])
        case .thick: style = StrokeStyle(lineWidth: 2.6)
        default: style = StrokeStyle(lineWidth: 1.4)
        }
        context.stroke(path, with: .color(color), style: style)
        guard edge.arrow else { return }
        let angle: CGFloat = horizontal ? (forward ? 0 : .pi) : (forward ? .pi / 2 : -.pi / 2)
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle - 0.4), y: end.y - 8 * sin(angle - 0.4)))
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle + 0.4), y: end.y - 8 * sin(angle + 0.4)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

private struct NodeView: View {
    let node: MermaidGraph.Node

    var body: some View {
        ZStack {
            shape
            Text(node.label)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, node.shape == .diamond ? 22 : 10)
                .padding(.top, node.shape == .cylinder ? 8 : 0)
        }
    }

    @ViewBuilder private var shape: some View {
        let fill = Color.accentColor.opacity(0.12), stroke = Color.accentColor.opacity(0.7)
        switch node.shape {
        case .box, .subroutine, .flag:
            RoundedRectangle(cornerRadius: 4).fill(fill).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(stroke))
                .overlay { if node.shape == .subroutine { HStack { Rectangle().fill(stroke).frame(width: 1); Spacer(); Rectangle().fill(stroke).frame(width: 1) }.padding(.horizontal, 6) } }
        case .rounded:
            RoundedRectangle(cornerRadius: 12).fill(fill).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(stroke))
        case .stadium:
            Capsule().fill(fill).overlay(Capsule().strokeBorder(stroke))
        case .circle:
            Circle().fill(fill).overlay(Circle().strokeBorder(stroke))
        case .diamond:
            Diamond().fill(fill).overlay(Diamond().stroke(stroke))
        case .cylinder:
            Cylinder().fill(Color.orange.opacity(0.12)).overlay(Cylinder().stroke(Color.orange.opacity(0.7)))
        }
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

/// A database: a box with elliptical ends.
private struct Cylinder: Shape {
    func path(in rect: CGRect) -> Path {
        let cap: CGFloat = min(10, rect.height / 4)
        return Path { path in
            path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cap * 2))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + cap))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cap))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - cap),
                          control1: CGPoint(x: rect.minX, y: rect.maxY + cap / 3), control2: CGPoint(x: rect.maxX, y: rect.maxY + cap / 3))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cap))
        }
    }
}
