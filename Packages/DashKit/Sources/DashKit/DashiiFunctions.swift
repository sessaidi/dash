import Foundation

/// General-purpose Dashii jobs any extension, Dashii or agent can run (`host.runFunction`): the
/// building blocks for "ask a smaller model about this" without writing a prompt each time.
/// Each one is cheap by default (fast model, low effort) and returns structured JSON.
public enum DashiiFunctions {
    public static var all: [AnyDashiiFunction] {
        [summarize.erased, classify.erased, extract.erased, rank.erased, digestLogs.erased, compare.erased, rootCause.erased]
    }

    // MARK: Summarize

    public struct SummarizeInput: Codable, Sendable {
        public var text: String
        /// What the reader cares about ("impact on the API", "decisions").
        public var focus: String?
        public var maxBullets: Int?
        public init(text: String, focus: String? = nil, maxBullets: Int? = nil) {
            self.text = text
            self.focus = focus
            self.maxBullets = maxBullets
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var summary: String
        public var bullets: [String]
    }

    public static let summarize = DashiiFunction<SummarizeInput, Summary>(
        name: "summarize", summary: "Summarize text: one sentence and a few bullets, optionally around a focus.",
        instructions: """
            Summarize the input text for a busy engineer: one plain sentence, then at most maxBullets (default 5) \
            short bullets with the facts that matter, around `focus` when given. Never invent facts.
            """,
        inputSchema: JSONSchema.object(properties: ["text": JSONSchema.string("The text."), "focus": JSONSchema.string("What matters to the reader."),
                                                    "maxBullets": JSONSchema.integer("At most this many bullets.")], required: ["text"]),
        outputSchema: JSONSchema.object(properties: ["summary": JSONSchema.string(""), "bullets": JSONSchema.array("", of: JSONSchema.string(""))],
                                        required: ["summary", "bullets"]),
        model: .fast, effort: .low, cacheFor: .seconds(3600))

    // MARK: Classify

    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var text: String
        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct ClassifyInput: Codable, Sendable {
        public var items: [Item]
        public var labels: [String]
        public var instructions: String?
        public init(items: [Item], labels: [String], instructions: String? = nil) {
            self.items = items
            self.labels = labels
            self.instructions = instructions
        }
    }

    public struct Classification: Codable, Sendable, Equatable {
        public struct Result: Codable, Sendable, Equatable {
            public var id: String
            public var label: String
            public var confidence: Double
            public var reason: String
        }
        public var results: [Result]
    }

    public static let classify = DashiiFunction<ClassifyInput, Classification>(
        name: "classify", summary: "Put each item under one of the given labels, with a confidence and a short reason.",
        instructions: "Give every item exactly one of `labels` (follow `instructions` when given), a confidence from 0 to 1 and a one-line reason.",
        inputSchema: JSONSchema.object(properties: [
            "items": JSONSchema.array("Things to classify.", of: JSONSchema.object(properties: ["id": JSONSchema.string(""), "text": JSONSchema.string("")], required: ["id", "text"])),
            "labels": JSONSchema.array("The allowed labels.", of: JSONSchema.string("")),
            "instructions": JSONSchema.string("How to decide."),
        ], required: ["items", "labels"]),
        outputSchema: JSONSchema.object(properties: ["results": JSONSchema.array("", of: JSONSchema.object(properties: [
            "id": JSONSchema.string(""), "label": JSONSchema.string(""), "confidence": JSONSchema.number(""), "reason": JSONSchema.string(""),
        ], required: ["id", "label", "confidence", "reason"]))], required: ["results"]),
        model: .fast, effort: .low, inputFormat: .compact, cacheFor: .seconds(3600),
        check: { classification in
            guard classification.results.allSatisfy({ (0...1).contains($0.confidence) }) else { throw ToolError("confidence must be between 0 and 1") }
        })

    // MARK: Extract

    public struct ExtractInput: Codable, Sendable {
        public struct Field: Codable, Sendable {
            public var name: String
            public var description: String
            public init(name: String, description: String) {
                self.name = name
                self.description = description
            }
        }
        public var text: String
        public var fields: [Field]
        public init(text: String, fields: [Field]) {
            self.text = text
            self.fields = fields
        }
    }

    public struct Extraction: Codable, Sendable, Equatable {
        /// Field name to the value found, as text.
        public var values: [String: String]
        /// Fields the text doesn't say.
        public var missing: [String]
    }

    public static let extract = DashiiFunction<ExtractInput, Extraction>(
        name: "extract", summary: "Pull named fields out of free text (owner, date, version, ticket…); lists what isn't there.",
        instructions: "Fill each field from the text only, as short text. A field the text doesn't state goes in `missing`, never guessed.",
        inputSchema: JSONSchema.object(properties: [
            "text": JSONSchema.string("The text."),
            "fields": JSONSchema.array("What to pull out.", of: JSONSchema.object(properties: ["name": JSONSchema.string(""), "description": JSONSchema.string("")], required: ["name", "description"])),
        ], required: ["text", "fields"]),
        outputSchema: JSONSchema.object(properties: [
            "values": ["type": "object", "additionalProperties": ["type": "string"]],
            "missing": JSONSchema.array("", of: JSONSchema.string("")),
        ], required: ["values", "missing"]),
        model: .fast, effort: .low, cacheFor: .seconds(3600))

    // MARK: Rank

    public struct RankInput: Codable, Sendable {
        public var items: [Item]
        /// What "first" means ("most urgent for on-call", "most likely to break prod").
        public var goal: String
        public init(items: [Item], goal: String) {
            self.items = items
            self.goal = goal
        }
    }

    public struct Ranking: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            public var id: String
            public var score: Double
            public var reason: String
        }
        public var ranked: [Entry]
    }

    public static let rank = DashiiFunction<RankInput, Ranking>(
        name: "rank", summary: "Order items by a goal (urgency, risk, relevance), each with a 0–1 score and a reason.",
        instructions: "Order every item by how well it matches `goal`, best first, with a score from 0 to 1 and a one-line reason.",
        inputSchema: JSONSchema.object(properties: [
            "items": JSONSchema.array("", of: JSONSchema.object(properties: ["id": JSONSchema.string(""), "text": JSONSchema.string("")], required: ["id", "text"])),
            "goal": JSONSchema.string("What first means."),
        ], required: ["items", "goal"]),
        outputSchema: JSONSchema.object(properties: ["ranked": JSONSchema.array("", of: JSONSchema.object(properties: [
            "id": JSONSchema.string(""), "score": JSONSchema.number(""), "reason": JSONSchema.string(""),
        ], required: ["id", "score", "reason"]))], required: ["ranked"]),
        model: .fast, effort: .low, inputFormat: .compact)

    // MARK: Logs

    public struct LogsInput: Codable, Sendable {
        public var lines: [String]
        /// Service, environment, what's being investigated.
        public var context: String?
        public init(lines: [String], context: String? = nil) {
            self.lines = lines
            self.context = context
        }
    }

    public struct LogDigest: Codable, Sendable, Equatable {
        public struct Pattern: Codable, Sendable, Equatable {
            public var pattern: String
            public var count: Int
            public var severity: String
            public var example: String
        }
        public var summary: String
        public var patterns: [Pattern]
    }

    public static let digestLogs = DashiiFunction<LogsInput, LogDigest>(
        name: "logs.digest", summary: "Group log lines into recurring patterns with counts, severity and an example; one-line summary.",
        instructions: """
            Group the log lines into recurring patterns (variable parts like ids, timestamps and numbers replaced by <…>), \
            most frequent errors first. Severity is error, warning or info. Quote one real line per pattern as `example`. \
            The summary says what's going wrong, if anything, in one sentence. Never paste secrets.
            """,
        inputSchema: JSONSchema.object(properties: ["lines": JSONSchema.array("Log lines.", of: JSONSchema.string("")),
                                                    "context": JSONSchema.string("What these logs are.")], required: ["lines"]),
        outputSchema: JSONSchema.object(properties: [
            "summary": JSONSchema.string(""),
            "patterns": JSONSchema.array("", of: JSONSchema.object(properties: [
                "pattern": JSONSchema.string(""), "count": JSONSchema.integer(""),
                "severity": JSONSchema.string("", enum: ["error", "warning", "info"]), "example": JSONSchema.string(""),
            ], required: ["pattern", "count", "severity", "example"])),
        ], required: ["summary", "patterns"]),
        model: .fast, effort: .low, cacheFor: .seconds(600))

    // MARK: Compare

    public struct CompareInput: Codable, Sendable {
        public var before: JSONValue
        public var after: JSONValue
        /// What to look for ("what changed in the deployment", "is the new config risky").
        public var question: String?
        public init(before: JSONValue, after: JSONValue, question: String? = nil) {
            self.before = before
            self.after = after
            self.question = question
        }
    }

    public struct Comparison: Codable, Sendable, Equatable {
        public var changes: [String]
        public var impact: String
        public var risk: String
    }

    public static let compare = DashiiFunction<CompareInput, Comparison>(
        name: "compare", summary: "What changed between two versions of something (config, deployment, release) and how risky it is.",
        instructions: "List the meaningful changes from `before` to `after` (ignore noise like timestamps), their likely impact, and a risk of low, medium or high with why.",
        inputSchema: JSONSchema.object(properties: ["before": JSONSchema.object("Any JSON."), "after": JSONSchema.object("Any JSON."),
                                                    "question": JSONSchema.string("What to look for.")], required: ["before", "after"]),
        outputSchema: JSONSchema.object(properties: ["changes": JSONSchema.array("", of: JSONSchema.string("")), "impact": JSONSchema.string(""),
                                                     "risk": JSONSchema.string("low, medium or high, and why.")], required: ["changes", "impact", "risk"]),
        model: .balanced, effort: .low, cacheFor: .seconds(600))

    // MARK: Root cause

    public struct Evidence: Codable, Sendable, Equatable {
        public var id: String
        /// Where it comes from: "datadog monitor 123", "pod api-1 events", "release v1.4".
        public var source: String
        public var detail: String
        public var at: String?
        public init(id: String, source: String, detail: String, at: String? = nil) {
            self.id = id
            self.source = source
            self.detail = detail
            self.at = at
        }
    }

    public struct RootCauseInput: Codable, Sendable {
        public var symptom: String
        public var evidence: [Evidence]
        public init(symptom: String, evidence: [Evidence]) {
            self.symptom = symptom
            self.evidence = evidence
        }
    }

    public struct RootCause: Codable, Sendable, Equatable {
        public struct Hypothesis: Codable, Sendable, Equatable {
            public var cause: String
            public var likelihood: Double
            /// Ids of the evidence that supports it.
            public var evidence: [String]
            public var nextCheck: String
        }
        public var summary: String
        public var hypotheses: [Hypothesis]
    }

    public static let rootCause = DashiiFunction<RootCauseInput, RootCause>(
        name: "root_cause", summary: "Likely causes of a symptom from pieces of evidence, ranked, each citing the evidence and the next check.",
        instructions: """
            You are a senior SRE. From the evidence only, give up to 4 hypotheses for the symptom, most likely first, \
            each with a likelihood from 0 to 1, the ids of the evidence supporting it, and the single next check that would \
            confirm or rule it out. Prefer recent changes and correlated timing. Say so when the evidence is too thin.
            """,
        inputSchema: JSONSchema.object(properties: [
            "symptom": JSONSchema.string("What's wrong."),
            "evidence": JSONSchema.array("", of: JSONSchema.object(properties: [
                "id": JSONSchema.string(""), "source": JSONSchema.string(""), "detail": JSONSchema.string(""), "at": JSONSchema.string("When."),
            ], required: ["id", "source", "detail"])),
        ], required: ["symptom", "evidence"]),
        outputSchema: JSONSchema.object(properties: [
            "summary": JSONSchema.string(""),
            "hypotheses": JSONSchema.array("", of: JSONSchema.object(properties: [
                "cause": JSONSchema.string(""), "likelihood": JSONSchema.number(""),
                "evidence": JSONSchema.array("", of: JSONSchema.string("")), "nextCheck": JSONSchema.string(""),
            ], required: ["cause", "likelihood", "evidence", "nextCheck"])),
        ], required: ["summary", "hypotheses"]),
        model: .balanced, effort: .medium, inputFormat: .compact,
        check: { result in
            let known = Set(result.hypotheses.flatMap(\.evidence))
            guard result.hypotheses.allSatisfy({ (0...1).contains($0.likelihood) && !$0.evidence.isEmpty }), !known.isEmpty || result.hypotheses.isEmpty else {
                throw ToolError("each hypothesis needs a likelihood from 0 to 1 and at least one evidence id")
            }
        })
}
