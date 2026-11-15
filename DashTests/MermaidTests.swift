import Foundation
import SwiftUI
import Testing
@testable import Dash

/// Mermaid flowcharts parsed for native drawing.
@MainActor
struct MermaidTests {
    static let bill = """
        flowchart LR
          subgraph Clients
            CTV[CTV / Roku / Smart TV]
            MOB[Mobile]
          end
          Clients --> PROXY[PROXY api gateway]
          PROXY --> BILL[billing-api]
          BILL --> KG[(Knowledge graph)]
          PM[Page Manager / CMS] -- Pub/Sub updates --> BILL
          BILL -.->|reads| page-cache{Cache?}
          A & B ==> C((done))
        """

    @Test func parsesShapesEdgesAndGroups() throws {
        let graph = try #require(MermaidGraph.parse(Self.bill))
        #expect(graph.direction == .leftToRight)
        let shapes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.shape) })
        #expect(shapes["KG"] == .cylinder && shapes["page-cache"] == .diamond && shapes["C"] == .circle && shapes["CTV"] == .box)
        #expect(graph.nodes.first { $0.id == "CTV" }?.group == "Clients" && graph.groups.map(\.title) == ["Clients"])
        #expect(graph.edges.contains(MermaidGraph.Edge(from: "PM", to: "BILL", label: "Pub/Sub updates", line: .solid, arrow: true)))
        #expect(graph.edges.contains(MermaidGraph.Edge(from: "BILL", to: "page-cache", label: "reads", line: .dotted, arrow: true)))
        #expect(graph.edges.filter { $0.to == "C" }.map(\.from) == ["A", "B"] && graph.edges.last?.line == .thick)
    }

    @Test func layersFollowTheEdges() throws {
        let graph = try #require(MermaidGraph.parse(Self.bill))
        let layout = graph.layout { _ in CGSize(width: 100, height: 40) }
        let frames = layout.frames
        #expect(frames["PROXY"]!.minX < frames["BILL"]!.minX && frames["BILL"]!.minX < frames["KG"]!.minX)
        #expect(layout.size.width > frames["KG"]!.maxX)
        // No two nodes overlap.
        let all = Array(frames.values)
        for i in all.indices { for j in all.indices where i < j { #expect(!all[i].intersects(all[j])) } }
    }

    /// Edges run horizontally or vertically only, never through a node, and labels don't overlap.
    @Test func orthogonalRoutesAvoidNodes() throws {
        let text = Self.bill + "\n  PROXY --> KG\n  KG --> PROXY"
        let graph = try #require(MermaidGraph.parse(text))
        for direction in [MermaidGraph.Direction.leftToRight, .topToBottom] {
            var oriented = graph
            oriented.direction = direction
            let layout = oriented.layout { _ in CGSize(width: 110, height: 40) }
            #expect(layout.routes.count == oriented.edges.count)
            for (index, route) in layout.routes.enumerated() {
                let edge = oriented.edges[index]
                #expect(route.count >= 2)
                for k in 0..<(route.count - 1) {
                    let a = route[k], b = route[k + 1]
                    #expect(abs(a.x - b.x) < 0.5 || abs(a.y - b.y) < 0.5, "edge \(edge.from)→\(edge.to) segment \(k) is diagonal")
                    let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(abs(a.x - b.x), 0.5), height: max(abs(a.y - b.y), 0.5))
                    for (id, frame) in layout.frames where id != edge.from && id != edge.to {
                        #expect(!segment.intersects(frame.insetBy(dx: 2, dy: 2)), "edge \(edge.from)→\(edge.to) crosses \(id)")
                    }
                }
            }
            let labels = layout.labels.compactMap { $0 }.map { CGRect(x: $0.x - 30, y: $0.y - 7, width: 60, height: 14) }
            for i in labels.indices { for j in labels.indices where i < j { #expect(!labels[i].intersects(labels[j])) } }
        }
    }

    /// Printed (PDF): drawn without scrolling, scaled into the page.
    @Test func printsScaledToThePage() throws {
        let graph = try #require(MermaidGraph.parse(Self.bill))
        let renderer = ImageRenderer(content: MermaidView(graph: graph, fit: CGSize(width: 300, height: 400)).frame(width: 300))
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 300 && image.size.height > 40 && image.size.height <= 420)
    }

    @Test func categoriesAndColours() throws {
        let graph = try #require(MermaidGraph.parse(Self.bill + """

              Q[Pub/Sub topic]:::hot
              R[(Redis cache)]
              classDef hot fill:#ffeeee,stroke:#f00
              style PROXY fill:#eef,color:#333
            """))
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        #expect(byID["KG"]?.category == .database && byID["CTV"]?.category == .client && byID["PROXY"]?.category == .gateway)
        #expect(byID["Q"]?.category == .queue && byID["R"]?.category == .cache && byID["page-cache"]?.category == .decision)
        #expect(byID["Q"]?.fill == "#ffeeee" && byID["Q"]?.stroke == "#f00")
        #expect(byID["PROXY"]?.fill == "#eef" && byID["PROXY"]?.text == "#333")
        #expect(Color(hex: "#f9f") != nil && Color(hex: "red") == nil)
    }

    @Test func otherDiagramsStayCode() {
        #expect(MermaidGraph.parse("sequenceDiagram\n A->>B: hi") == nil)
        #expect(MermaidGraph.parse("graph TD\n A --> B")?.direction == .topToBottom)
    }
}
