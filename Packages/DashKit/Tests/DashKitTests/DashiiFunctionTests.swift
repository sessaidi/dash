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
