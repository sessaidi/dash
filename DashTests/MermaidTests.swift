import Foundation
import Testing
@testable import Dash

/// Mermaid flowcharts parsed for native drawing.
@MainActor
struct MermaidTests {
    static let papi = """
        flowchart LR
          subgraph Clients
            CTV[CTV / Roku / Smart TV]
            MOB[Mobile]
          end
          Clients --> CAPIG[CAPIG api gateway]
          CAPIG --> PAPI[services-presentation-api]
          PAPI --> KG[(Knowledge graph)]
          PM[Page Manager / CMS] -- Pub/Sub updates --> PAPI
          PAPI -.->|reads| page-cache{Cache?}
          A & B ==> C((done))
        """

    @Test func parsesShapesEdgesAndGroups() throws {
        let graph = try #require(MermaidGraph.parse(Self.papi))
        #expect(graph.direction == .leftToRight)
        let shapes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.shape) })
        #expect(shapes["KG"] == .cylinder && shapes["page-cache"] == .diamond && shapes["C"] == .circle && shapes["CTV"] == .box)
        #expect(graph.nodes.first { $0.id == "CTV" }?.group == "Clients" && graph.groups.map(\.title) == ["Clients"])
        #expect(graph.edges.contains(MermaidGraph.Edge(from: "PM", to: "PAPI", label: "Pub/Sub updates", line: .solid, arrow: true)))
        #expect(graph.edges.contains(MermaidGraph.Edge(from: "PAPI", to: "page-cache", label: "reads", line: .dotted, arrow: true)))
        #expect(graph.edges.filter { $0.to == "C" }.map(\.from) == ["A", "B"] && graph.edges.last?.line == .thick)
    }

    @Test func layersFollowTheEdges() throws {
        let graph = try #require(MermaidGraph.parse(Self.papi))
        let layout = graph.layout { _ in CGSize(width: 100, height: 40) }
        let frames = layout.frames
        #expect(frames["CAPIG"]!.minX < frames["PAPI"]!.minX && frames["PAPI"]!.minX < frames["KG"]!.minX)
        #expect(layout.size.width > frames["KG"]!.maxX)
        // No two nodes overlap.
        let all = Array(frames.values)
        for i in all.indices { for j in all.indices where i < j { #expect(!all[i].intersects(all[j])) } }
    }

    @Test func otherDiagramsStayCode() {
        #expect(MermaidGraph.parse("sequenceDiagram\n A->>B: hi") == nil)
        #expect(MermaidGraph.parse("graph TD\n A --> B")?.direction == .topToBottom)
    }
}
