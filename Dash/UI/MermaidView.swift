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
        /// Per edge (same order as `edges`): an orthogonal polyline from source to target.
        var routes: [[CGPoint]] = []
        /// Per edge: where its label goes (nil without a label).
        var labels: [CGPoint?] = []
    }

    /// Layered layout with orthogonal routing. Nodes are ranked by longest path; an edge that spans
    /// several layers gets a placeholder in each layer it crosses (so it never runs through a node);
    /// ranks are ordered by the average position of neighbours; each edge turns in the gap between
    /// two layers on its own lane; back edges go round the outside. `labelSize` measures labels.
    func layout(size measure: (Node) -> CGSize, labelSize: (String) -> CGSize = { CGSize(width: CGFloat($0.count) * 6 + 10, height: 16) }) -> Layout {
        let ids = nodes.map(\.id)
        let horizontal = isHorizontal
        // Ranks: longest path, cycle-safe (relax at most nodes.count times).
        var rank: [String: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
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

        // Forward edges become chains through placeholders; back edges and self loops are routed apart.
        var chains: [[String]] = Array(repeating: [], count: edges.count)
        var segments: [(String, String)] = []
        var dummyLayer: [String: Int] = [:]
        for (index, edge) in edges.enumerated() {
            guard let a = rank[edge.from], let b = rank[edge.to], b > a else { continue }
            var chain = [edge.from]
            for level in (a + 1)..<b {
                let id = "~\(index)~\(level)"
                layers[level].append(id)
                dummyLayer[id] = level
                chain.append(id)
            }
            chain.append(edge.to)
            chains[index] = chain
            for k in 0..<(chain.count - 1) { segments.append((chain[k], chain[k + 1])) }
        }

        // Order within layers: barycenter sweeps, subgraph members kept together.
        let groupIndex: [String: Int] = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        let groupOf = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.group.flatMap { groupIndex[$0] } ?? -1) })
        for sweep in 0..<6 where maxRank > 0 {
            let down = sweep % 2 == 0
            for level in (down ? Array(1...maxRank) : Array((0..<maxRank).reversed())) {
                let neighbour = layers[down ? level - 1 : level + 1]
                let position = Dictionary(uniqueKeysWithValues: neighbour.enumerated().map { ($1, Double($0)) })
                let current = layers[level]
                var keys: [String: (Int, Double)] = [:]
                for (offset, id) in current.enumerated() {
                    let linked = segments.compactMap { down ? ($0.1 == id ? position[$0.0] : nil) : ($0.0 == id ? position[$0.1] : nil) }
                    let centre = linked.isEmpty ? Double(offset) : linked.reduce(0, +) / Double(linked.count)
                    keys[id] = (groupOf[id] ?? -1, centre)
                }
                layers[level].sort { keys[$0]! < keys[$1]! }
            }
        }

        // Sizes in layer space: `along` crosses layers, `across` runs within a layer.
        var along: [String: CGFloat] = [:], across: [String: CGFloat] = [:]
        for node in nodes {
            let size = measure(node)
            along[node.id] = horizontal ? size.width : size.height
            across[node.id] = horizontal ? size.height : size.width
        }
        for id in dummyLayer.keys { along[id] = 0; across[id] = 6 }

        // Lanes: how many segments turn in each gap, which sets how wide the gap is.
        func layerOf(_ id: String) -> Int { rank[id] ?? dummyLayer[id] ?? 0 }
        var lanesPerGap = [Int](repeating: 0, count: maxRank + 1)
        for (a, _) in segments { lanesPerGap[layerOf(a)] += 1 }
        let margin: CGFloat = 40, gapAcross: CGFloat = 26
        var gapAlong = lanesPerGap.map { max(64, CGFloat($0 + 1) * 10) }

        // Positions: layers left to right (or top to bottom), centred across.
        var thickness: [CGFloat] = layers.map { layer in layer.map { along[$0] ?? 0 }.max() ?? 0 }
        let lengths = layers.map { layer in layer.reduce(0) { $0 + (across[$1] ?? 0) } + gapAcross * CGFloat(max(layer.count - 1, 0)) }
        let widest = lengths.max() ?? 0
        var start: [CGFloat] = [], cursor = margin
        for level in layers.indices {
            start.append(cursor)
            cursor += thickness[level] + (level < gapAlong.count ? gapAlong[level] : 0)
        }
        var a0: [String: CGFloat] = [:], c0: [String: CGFloat] = [:]
        for (level, layer) in layers.enumerated() {
            var c = margin + 20 + (widest - lengths[level]) / 2
            for id in layer {
                a0[id] = start[level] + (thickness[level] - (along[id] ?? 0)) / 2
                c0[id] = c
                c += (across[id] ?? 0) + gapAcross
            }
        }
        let extentAlong = cursor - (gapAlong.last ?? 0) + margin
        var extentAcross = margin * 2 + 40 + widest

        // Ports: edges leaving or entering a side spread along it, ordered by where they go.
        var outgoing: [String: [Int]] = [:], incoming: [String: [Int]] = [:]
        for (index, chain) in chains.enumerated() where chain.count > 1 {
            outgoing[chain[0], default: []].append(index)
            incoming[chain[chain.count - 1], default: []].append(index)
        }
        func centreAcross(_ id: String) -> CGFloat { (c0[id] ?? 0) + (across[id] ?? 0) / 2 }
        func port(_ id: String, edge: Int, list: [String: [Int]], other: (Int) -> String) -> CGFloat {
            let attached = (list[id] ?? []).sorted { centreAcross(other($0)) < centreAcross(other($1)) }
            guard attached.count > 1, let position = attached.firstIndex(of: edge), (across[id] ?? 0) > 0 else { return centreAcross(id) }
            let span = (across[id] ?? 0) * 0.6
            return centreAcross(id) - span / 2 + span * CGFloat(position) / CGFloat(attached.count - 1)
        }

        // Lane per segment in its gap, ordered by where it starts to limit crossings.
        var laneOf: [String: CGFloat] = [:]
        for level in 0...maxRank {
            let inGap = segments.filter { layerOf($0.0) == level }.sorted { centreAcross($0.0) == centreAcross($1.0) ? centreAcross($0.1) < centreAcross($1.1) : centreAcross($0.0) < centreAcross($1.0) }
            let gapStart = start[level] + thickness[level]
            for (k, segment) in inGap.enumerated() {
                laneOf[segment.0 + "→" + segment.1] = gapStart + (gapAlong[level]) * CGFloat(k + 1) / CGFloat(inGap.count + 1)
            }
        }

        // Routes in layer space (a, c).
        var abstract: [[CGPoint]] = Array(repeating: [], count: edges.count)
        var below = extentAcross - margin
        for (index, edge) in edges.enumerated() {
            let chain = chains[index]
            if chain.count > 1 {
                var points: [CGPoint] = []
                for k in 0..<(chain.count - 1) {
                    let a = chain[k], b = chain[k + 1]
                    let ca = k == 0 ? port(a, edge: index, list: outgoing) { chains[$0][1] } : centreAcross(a)
                    let cb = k == chain.count - 2 ? port(b, edge: index, list: incoming) { chains[$0][chains[$0].count - 2] } : centreAcross(b)
                    let exit = (a0[a] ?? 0) + (along[a] ?? 0)
                    let entry = a0[b] ?? 0
                    if points.isEmpty { points.append(CGPoint(x: exit, y: ca)) } else { points.append(CGPoint(x: exit, y: ca)) }
                    if abs(ca - cb) > 0.5 {
                        let lane = laneOf[a + "→" + b] ?? (exit + entry) / 2
                        points.append(CGPoint(x: lane, y: ca))
                        points.append(CGPoint(x: lane, y: cb))
                    }
                    points.append(CGPoint(x: entry, y: cb))
                }
                abstract[index] = Self.simplified(points)
            } else if let from = a0[edge.from], let to = a0[edge.to] {
                // Back edge or self loop: out, round the far side of the drawing, back in.
                below += 12
                let exit = from + (along[edge.from] ?? 0), entry = to
                let out = exit + 14, back = entry - 14
                abstract[index] = [CGPoint(x: exit, y: centreAcross(edge.from)), CGPoint(x: out, y: centreAcross(edge.from)),
                                   CGPoint(x: out, y: below), CGPoint(x: back, y: below), CGPoint(x: back, y: centreAcross(edge.to)),
                                   CGPoint(x: entry, y: centreAcross(edge.to))]
            }
        }
        extentAcross = max(extentAcross, below + margin)

        // To screen space, mirrored for right-to-left and bottom-to-top.
        let width = horizontal ? extentAlong : extentAcross, height = horizontal ? extentAcross : extentAlong
        func screen(_ p: CGPoint) -> CGPoint {
            var point = horizontal ? p : CGPoint(x: p.y, y: p.x)
            if direction == .rightToLeft { point.x = width - point.x }
            if direction == .bottomToTop { point.y = height - point.y }
            return point
        }
        var frames: [String: CGRect] = [:]
        for node in nodes {
            guard let a = a0[node.id], let c = c0[node.id] else { continue }
            let corners = [screen(CGPoint(x: a, y: c)), screen(CGPoint(x: a + (along[node.id] ?? 0), y: c + (across[node.id] ?? 0)))]
            frames[node.id] = CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                                     width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y))
        }
        let routes = abstract.map { $0.map(screen) }

        var groupFrames: [String: CGRect] = [:]
        for group in groups {
            let members = nodes.filter { $0.group == group.id }.compactMap { frames[$0.id] }
            guard let first = members.first else { continue }
            let bounds = members.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -12, dy: -12)
            groupFrames[group.id] = CGRect(x: bounds.minX, y: bounds.minY - 18, width: bounds.width, height: bounds.height + 18)
        }

        // Labels: on the edge's longest segment, nudged until they hit no node and no other label.
        var taken = Array(frames.values)
        var labels: [CGPoint?] = []
        for (index, edge) in edges.enumerated() {
            guard let text = edge.label, routes[index].count > 1 else { labels.append(nil); continue }
            let size = labelSize(text)
            let route = routes[index]
            let longest = (0..<(route.count - 1)).max { hypot(route[$0 + 1].x - route[$0].x, route[$0 + 1].y - route[$0].y) < hypot(route[$1 + 1].x - route[$1].x, route[$1 + 1].y - route[$1].y) }!
            let a = route[longest], b = route[longest + 1]
            let vertical = abs(a.x - b.x) < 0.5
            var spot = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let step: CGFloat = vertical ? size.height + 2 : size.width / 2
            for attempt in 0..<12 {
                let rect = CGRect(x: spot.x - size.width / 2, y: spot.y - size.height / 2, width: size.width, height: size.height).insetBy(dx: -2, dy: -2)
                if !taken.contains(where: { $0.intersects(rect) }) { taken.append(rect); break }
                let shift = step * CGFloat((attempt / 2) + 1) * (attempt % 2 == 0 ? 1 : -1)
                spot = vertical ? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + shift) : CGPoint(x: (a.x + b.x) / 2 + shift, y: (a.y + b.y) / 2)
            }
            labels.append(spot)
        }

        var size = CGSize(width: width, height: height)
        for frame in groupFrames.values { size.width = max(size.width, frame.maxX + 8); size.height = max(size.height, frame.maxY + 8) }
        return Layout(frames: frames, groupFrames: groupFrames, size: size, routes: routes, labels: labels)
    }

    /// Drops points that don't turn the line.
    static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, abs(last.x - point.x) < 0.5, abs(last.y - point.y) < 0.5 { continue }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if (abs(a.x - b.x) < 0.5 && abs(b.x - point.x) < 0.5) || (abs(a.y - b.y) < 0.5 && abs(b.y - point.y) < 0.5) { result[result.count - 1] = point; continue }
            }
            result.append(point)
        }
        return result
    }
}

/// Draws a `MermaidGraph` with SwiftUI: shapes, labels, curved edges with arrows, subgraph boxes.
/// Scrolls when wider than the note.
struct MermaidView: View {
    let graph: MermaidGraph
    /// For print: no scrolling, scaled down to fit this size (a PDF page). nil scrolls on screen.
    var fit: CGSize? = nil
    @Environment(\.colorScheme) private var colorScheme

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var body: some View {
        let layout = graph.layout(size: Self.size, labelSize: Self.labelSize)
        if let fit {
            let scale = min(1, fit.width / max(layout.size.width, 1), fit.height / max(layout.size.height, 1))
            diagram(layout)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            ScrollView(.horizontal) { diagram(layout) }
                .scrollIndicators(.automatic)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        }
    }

    private func diagram(_ layout: MermaidGraph.Layout) -> some View {
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
                    for (index, edge) in graph.edges.enumerated() where index < layout.routes.count {
                        draw(edge, route: layout.routes[index], in: &context)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                ForEach(Array(graph.edges.enumerated()), id: \.offset) { index, edge in
                    if let label = edge.label, index < layout.labels.count, let spot = layout.labels[index] {
                        Text(label).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.background, in: .rect(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator.opacity(0.5)))
                            .fixedSize()
                            .position(spot)
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

    /// A label's room, as drawn (caption2 with padding).
    static func labelSize(_ text: String) -> CGSize {
        let bounds = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10)]).size()
        return CGSize(width: ceil(bounds.width) + 10, height: ceil(bounds.height) + 4)
    }

    /// An orthogonal polyline with softened corners and an arrowhead along its last segment.
    private func draw(_ edge: MermaidGraph.Edge, route: [CGPoint], in context: inout GraphicsContext) {
        guard route.count >= 2 else { return }
        var path = Path()
        path.move(to: route[0])
        for k in 1..<route.count {
            if k < route.count - 1 {
                let previous = route[k - 1], corner = route[k], next = route[k + 1]
                let radius = min(6, hypot(corner.x - previous.x, corner.y - previous.y) / 2, hypot(next.x - corner.x, next.y - corner.y) / 2)
                path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
            } else {
                path.addLine(to: route[k])
            }
        }
        let style: StrokeStyle
        switch edge.line {
        case .dotted: style = StrokeStyle(lineWidth: 1.4, dash: [4, 4])
        case .thick: style = StrokeStyle(lineWidth: 2.6)
        default: style = StrokeStyle(lineWidth: 1.4)
        }
        context.stroke(path, with: .color(.secondary), style: style)
        guard edge.arrow else { return }
        let end = route[route.count - 1], before = route[route.count - 2]
        let angle = atan2(end.y - before.y, end.x - before.x)
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle - 0.4), y: end.y - 8 * sin(angle - 0.4)))
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle + 0.4), y: end.y - 8 * sin(angle + 0.4)))
        head.closeSubpath()
        context.fill(head, with: .color(.secondary))
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
