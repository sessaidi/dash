import Foundation

/// Removes secrets from text and JSON before they reach Claude, the knowledge graph or logs:
/// tokens and keys by their well-known shapes, credentials in URLs and auth headers, and the
/// values of fields whose name says they're secret ("password", "API_KEY", "client_secret"…).
/// What it can't recognise passes through, so it's a safety net, not a guarantee.
public enum Sanitizer {
    public static let mask = "[REDACTED]"

    /// Field names whose values are secret, in JSON and in `NAME=value` / `name: value` text.
    nonisolated(unsafe) static let secretName = /(?i)^(.*[_\-.])?(password|passwd|pwd|secret|token|api[_\-]?key|apikey|private[_\-]?key|access[_\-]?key|client[_\-]?secret|auth|authorization|credentials?|session[_\-]?key|signing[_\-]?key|dsn)([_\-.].*)?$/

    private struct Pattern: @unchecked Sendable {
        let regex: Regex<AnyRegexOutput>
        /// Keep this many leading characters of the match (a prefix that says what it was).
        let keep: (Substring) -> String
    }

    nonisolated(unsafe) private static let patterns: [Pattern] = {
        func p(_ source: String, keep: @escaping (Substring) -> String = { _ in "" }) -> Pattern {
            // The sources are literals checked by the tests.
            Pattern(regex: try! Regex(source), keep: keep)
        }
        func prefix(_ length: Int) -> (Substring) -> String { { String($0.prefix(length)) } }
        return [
            p(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
            p(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, keep: prefix(4)),
            p(#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#, keep: prefix(4)),
            p(#"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#, keep: prefix(11)),
            p(#"\bglpat-[A-Za-z0-9_\-]{20,}"#, keep: prefix(6)),
            p(#"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#, keep: prefix(5)),
            p(#"\bAIza[0-9A-Za-z_\-]{35}\b"#, keep: prefix(4)),
            p(#"\bsk-ant-[A-Za-z0-9_\-]{20,}"#, keep: prefix(7)),
            p(#"\bsk-[A-Za-z0-9]{32,}\b"#, keep: prefix(3)),
            p(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
            p(#"(?i)\b(?:bearer|basic|token)\s+[A-Za-z0-9_\-.=+/]{16,}"#, keep: { match in String(match.prefix { !$0.isWhitespace }) + " " }),
            // user:password@host in URLs keeps the user.
            p(#"://[^/\s:@]+:[^/\s@]+(?=@)"#, keep: { match in "://" + String(match.dropFirst(3).prefix { $0 != ":" }) + ":" }),
            // NAME=value, name: value, "name": "value" in plain text.
            p(#"(?i)\b[A-Z0-9_.\-]*(?:password|passwd|secret|token|api[_\-]?key|apikey|private[_\-]?key|access[_\-]?key|client[_\-]?secret)[A-Z0-9_.\-]*["']?\s*[=:]\s*["']?[^\s"',;}]{4,}"#,
              keep: { match in
                  let separator = match.firstIndex { $0 == "=" || $0 == ":" } ?? match.endIndex
                  let head = match[..<separator]
                  let rest = match[separator...].prefix { $0 == "=" || $0 == ":" || $0 == " " || $0 == "\"" || $0 == "'" }
                  return String(head) + String(rest)
              }),
        ]
    }()

    /// The text with secrets replaced by `[REDACTED]`, and how many were found.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for pattern in patterns {
            result = result.replacing(pattern.regex) { match in
                count += 1
                return pattern.keep(match.output[0].substring ?? "") + mask
            }
        }
        return (result, count)
    }

    public static func clean(_ text: String) -> String { redact(text).text }

    /// The JSON with secret-named fields masked and secrets in strings redacted.
    public static func clean(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(clean(text))
        case .array(let items): .array(items.map(clean))
        case .object(let fields):
            .object(Dictionary(uniqueKeysWithValues: fields.map { key, field in
                if isSecretName(key), case .string(let text) = field, !text.isEmpty { return (key, .string(mask)) }
                return (key, clean(field))
            }))
        default: value
        }
    }

    public static func isSecretName(_ name: String) -> Bool {
        // "token_count", "max_tokens", "author" are not secrets.
        let lower = name.lowercased()
        if ["author", "authors", "authored", "authored_at", "auth_type", "authorization_url"].contains(lower) || lower.contains("count") || lower.hasSuffix("tokens") { return false }
        return lower.wholeMatch(of: secretName) != nil
    }
}
