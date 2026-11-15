import Foundation
import Testing
@testable import DashKit

/// The token-lean form tool results reach Dashii in: shorter than JSON, and nothing lost.
struct CompactFormatTests {
    static let pods: JSONValue = [
        "namespace": "bill-eu",
        "pods": [
            ["name": "api-1", "status": "Running", "restarts": 0, "ready": true],
            ["name": "api-2", "status": "CrashLoopBackOff", "restarts": 12, "ready": false, "reason": "OOMKilled"],
            ["name": "worker|blue", "status": "Pending", "restarts": 0, "ready": false, "labels": ["team": "core"]],
        ],
        "tags": ["blue", "green", "1.5", "true", ""],
        "owner": ["login": "me", "teams": [["id": 1], "text: with colon", ["nested": [1, 2]]]],
        "note": "line one\nline two",
        "empty": [:],
        "none": [],
        "gone": nil,
        "weird key": -1.25,
    ]

    @Test func tablesNameFieldsOnce() {
        let text = CompactFormat.encode(Self.pods)
        #expect(text.contains("pods[3]{labels|name|ready|reason|restarts|status}:"))
        #expect(text.contains("  |api-2|false|OOMKilled|12|CrashLoopBackOff"))
        #expect(text.contains("tags[5]: blue|green|\"1.5\"|\"true\"|\"\""))
        #expect(!text.contains("gone"))
    }

    /// Typical result: rows of the same fields. Well under two thirds of the JSON.
    @Test func muchShorterOnRows() {
        var rows: [JSONValue] = []
        for index in 1...20 {
            let failing = index % 5 == 0
            var row: [String: JSONValue] = ["namespace": "bill-eu", "age": "3h", "ready": .bool(!failing)]
            row["name"] = .string("billing-api-7d9f\(index)")
            row["status"] = .string(failing ? "CrashLoopBackOff" : "Running")
            row["restarts"] = .number(Double(index % 7))
            row["node"] = .string("gke-api-pool-\(index % 3)")
            rows.append(.object(row))
        }
        let value: JSONValue = ["pods": .array(rows), "count": 20]
        let (compact, json) = (CompactFormat.encode(value).utf8.count, value.jsonString().utf8.count)
        #expect(compact * 3 < json * 2, "\(compact) vs \(json) bytes")
    }

    @Test func readsBackWhatItWrote() throws {
        var expected = Self.pods
        if case .object(var fields) = expected { fields["gone"] = nil; expected = .object(fields) }
        #expect(try CompactFormat.decode(CompactFormat.encode(Self.pods)) == expected)
    }

    @Test func topLevelArraysAndScalars() throws {
        let rows: JSONValue = [["key": "KAN-1", "summary": "Fix: login"], ["key": "KAN-2", "summary": "a|b"]]
        let text = CompactFormat.encode(rows)
        #expect(text.hasPrefix("[2]{key|summary}:"))
        #expect(try CompactFormat.decode(text) == rows)
        for value: JSONValue in ["text", 3, true, nil, [], [:], [1, 2]] {
            #expect(try CompactFormat.decode(CompactFormat.encode(value)) == value)
        }
    }

    @Test func fallsBackToJSONWhenShorter() {
        let value: JSONValue = ["a": [["x": [["y": 1]]]]]
        let text = CompactFormat.encode(value)
        #expect(text.utf8.count <= value.jsonString().utf8.count)
    }
}

/// Writes an evaluation fixture (JSON and compact) when DASH_COMPACT_EVAL names a folder.
struct CompactFormatEvalFixture {
    @Test func dump() throws {
        guard let folder = ProcessInfo.processInfo.environment["DASH_COMPACT_EVAL"] else { return }
        let url = URL(filePath: folder)
        let fixture = try JSONValue.parse(String(contentsOf: url.appending(path: "fixture.json"), encoding: .utf8))
        try CompactFormat.encode(fixture).write(to: url.appending(path: "fixture.compact"), atomically: true, encoding: .utf8)
        #expect(try CompactFormat.decode(CompactFormat.encode(fixture)) == fixture)
    }
}
