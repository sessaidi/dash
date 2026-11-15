import DashKitTesting
import Foundation
import Testing
@testable import DashKit

/// Typed Dashii jobs: the request they send, how answers are read, retried, checked and cached.
@MainActor
@Suite(.serialized)
struct DashiiFunctionTests {
    struct Pods: Codable, Sendable { var pods: [Pod] }
    struct Pod: Codable, Sendable { var name: String; var restarts: Int }
    struct Triage: Codable, Sendable, Equatable { var culprit: String; var confidence: Double }

    static let schema: JSONValue = ["type": "object", "required": ["culprit", "confidence"],
                                    "properties": ["culprit": ["type": "string"], "confidence": ["type": "number"]]]
    static let input = Pods(pods: [Pod(name: "api-1", restarts: 0), Pod(name: "api-2", restarts: 9)])

    func triage(format: DashiiFunction<Pods, Triage>.InputFormat = .json, cacheFor: Duration? = nil) -> DashiiFunction<Pods, Triage> {
        DashiiFunction(name: "pods.triage", task: "triage", instructions: "Name the failing pod.", outputSchema: Self.schema,
                       model: .fast, effort: .low, inputFormat: format, cacheFor: cacheFor,
                       check: { triage in
                           guard (0...1).contains(triage.confidence) else { throw ToolError("confidence must be between 0 and 1") }
                       })
    }

    init() { DashiiFunctionCache.shared.removeAll() }

    @Test func sendsTheJobAndDecodesTheAnswer() async throws {
        let dashii = TestDashii()
        dashii.reply = #"{"culprit":"api-2","confidence":0.9}"#
        let answer = try await triage().run(Self.input, dashii: dashii)
        #expect(answer == Triage(culprit: "api-2", confidence: 0.9))
        let call = try #require(dashii.calls.first)
        #expect(call.system == "Name the failing pod.")
        #expect(call.prompt.contains(#""name":"api-2""#) && call.prompt.hasPrefix("<input>"))
        #expect(call.outputSchema == Self.schema && call.model == DashiiModel.fast.rawValue && call.effort == "low")
        #expect(call.source == "function.triage")
    }

    @Test func compactInputCarriesTheLegend() async throws {
        let dashii = TestDashii()
        dashii.reply = #"{"culprit":"api-2","confidence":0.5}"#
        _ = try await triage(format: .compact).run(Self.input, dashii: dashii)
        let call = try #require(dashii.calls.first)
        #expect(call.prompt.contains("pods[2]{name|restarts}:"))
        #expect(call.system.contains(CompactFormat.legend))
    }

    @Test func userChoicesWinOverDefaults() async throws {
        let dashii = TestDashii()
        dashii.reply = #"{"culprit":"api-2","confidence":0.5}"#
        let task = AITask(id: "triage", title: "Triage", summary: "", models: [.fast, .strong], defaultModel: .fast)
        let settings = AISettings(tasks: [task], choices: ["triage": AITaskChoice(model: .strong)], scope: .extension("sre"))
        _ = try await triage().run(Self.input, dashii: dashii, settings: settings)
        #expect(dashii.calls.first?.model == DashiiModel.strong.rawValue)
        #expect(dashii.calls.first?.source == "extension.sre/triage")
    }

    @Test func readsFencedOrWrappedJSON() {
        #expect(DashiiFunction<Pods, Triage>.json(in: "```json\n{\"a\":1}\n```") == #"{"a":1}"#)
        #expect(DashiiFunction<Pods, Triage>.json(in: "Here it is: {\"a\":1} hope it helps") == #"{"a":1}"#)
    }

    @Test func asksAgainOnceWithWhatWasWrong() async throws {
        let dashii = TestDashii()
        dashii.replies = ["Sure! The culprit is api-2.", #"{"culprit":"api-2","confidence":3}"#]
        await #expect(throws: ToolError.self) { try await triage().run(Self.input, dashii: dashii) }
        #expect(dashii.calls.count == 2)
        #expect(dashii.calls[1].prompt.contains("couldn't be used"))

        let retried = TestDashii()
        retried.replies = [#"{"culprit":"api-2"}"#, #"{"culprit":"api-2","confidence":0.8}"#]
        #expect(try await triage().run(Self.input, dashii: retried).confidence == 0.8)
        #expect(retried.calls[1].prompt.contains("missing confidence"))
    }

    @Test func cachesTheSameInput() async throws {
        let dashii = TestDashii()
        dashii.reply = #"{"culprit":"api-2","confidence":0.9}"#
        let function = triage(cacheFor: .seconds(600))
        _ = try await function.run(Self.input, dashii: dashii)
        _ = try await function.run(Self.input, dashii: dashii)
        #expect(dashii.calls.count == 1)
        _ = try await function.run(Pods(pods: []), dashii: dashii)
        #expect(dashii.calls.count == 2)
    }
}

/// The shared library and functions extensions publish, reached through the host by name.
@MainActor
@Suite(.serialized)
struct PublishedFunctionTests {
    final class Publisher: DashExtension {
        let id = "sre"
        let name = "SRE"
        let systemImage = "stethoscope"
        let metadata = ExtensionMetadata(version: "1.0.0", summary: "Test.")
        struct Alert: Codable, Sendable { var monitor: String }
        struct Verdict: Codable, Sendable { var page: Bool }
        var functions: [AnyDashiiFunction] {
            [DashiiFunction<Alert, Verdict>(name: "sre.should_page", summary: "Page or not.", instructions: "Decide.",
                                           outputSchema: ["type": "object"]).erased]
        }
    }

    init() { DashiiFunctionCache.shared.removeAll() }

    @Test func libraryAndExtensionFunctionsRunByName() async throws {
        let host = try TestHost([Publisher()])
        #expect(host.functions.map(\.name).prefix(7) == ["summarize", "classify", "extract", "rank", "logs.digest", "compare", "root_cause"])
        #expect(host.function("sre.should_page") != nil)

        host.testDashii.reply = #"{"page":true}"#
        #expect(try await host.runFunction("sre.should_page", input: ["monitor": "api 5xx"]) == ["page": true])
        #expect(host.testDashii.calls.last?.source == "function.sre.should_page")

        host.testDashii.reply = #"{"summary":"Disk full on api-1.","patterns":[{"pattern":"ENOSPC <path>","count":3,"severity":"error","example":"ENOSPC /data"}]}"#
        let digest = try await host.runFunction("logs.digest", input: ["lines": ["ENOSPC /data", "ENOSPC /tmp", "ENOSPC /var"]])
        #expect(digest["patterns"]?[0]?["count"] == 3)

        await #expect(throws: ToolError.self) { try await host.runFunction("nope", input: [:]) }
        await #expect(throws: ToolError.self) { try await host.runFunction("summarize", input: ["focus": "no text"]) }
    }

    @Test func rootCauseNeedsEvidence() async throws {
        let dashii = TestDashii()
        dashii.replies = [#"{"summary":"?","hypotheses":[{"cause":"deploy","likelihood":0.7,"evidence":[],"nextCheck":"diff"}]}"#,
                          #"{"summary":"Deploy","hypotheses":[{"cause":"deploy","likelihood":0.7,"evidence":["e1"],"nextCheck":"diff"}]}"#]
        let input = DashiiFunctions.RootCauseInput(symptom: "5xx", evidence: [.init(id: "e1", source: "release", detail: "v2 at 10:02")])
        let result = try await DashiiFunctions.rootCause.run(input, dashii: dashii)
        #expect(result.hypotheses.first?.evidence == ["e1"] && dashii.calls.count == 2)
    }
}
