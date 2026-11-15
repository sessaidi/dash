import DashKit
import Foundation
import Testing

/// Secrets never reach Claude, the knowledge graph or logs.
struct SanitizerTests {
    @Test(arguments: [
        ("export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_abcdefghij"),
        ("key AKIAIOSFODNN7EXAMPLE in env", "IOSFODNN7EXAMPLE"),
        ("glpat-AbCdEfGhIjKlMnOpQrSt1234", "AbCdEfGhIjKlMnOp"),
        ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456", "abcdefghijklmnop"),
        ("postgres://app:hunter2secret@db.internal:5432/x", "hunter2secret"),
        ("DB_PASSWORD=correcthorse", "correcthorse"),
        ("\"client_secret\": \"s3cr3tvalue\"", "s3cr3tvalue"),
        ("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "dozjgNryP4J3"),
        ("-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----", "MIIEow"),
        ("sk-ant-api03-abcdefghijklmnopqrstuv", "abcdefghijklmnop"),
    ])
    func redactsSecrets(_ input: String, _ secret: String) {
        let (text, count) = Sanitizer.redact(input)
        #expect(!text.contains(secret), "\(text)")
        #expect(text.contains(Sanitizer.mask) && count >= 1)
    }

    @Test func keepsOrdinaryText() {
        let text = "PR #42 by octocat: max_tokens 4096, author alice, see https://github.com/acme/api/pull/42. Commit 3f2a9c1e8b7d."
        #expect(Sanitizer.clean(text) == text)
    }

    @Test func masksSecretFieldsInJSON() {
        let value: JSONValue = ["name": "api", "password": "pw123", "env": ["API_KEY": "abc", "REGION": "eu"],
                                "author": "alice", "token_count": 12, "logs": "set SECRET=topsecret1"]
        let clean = Sanitizer.clean(value)
        #expect(clean["password"] == .string(Sanitizer.mask) && clean["env"]?["API_KEY"] == .string(Sanitizer.mask))
        #expect(clean["env"]?["REGION"] == "eu" && clean["author"] == "alice" && clean["token_count"] == 12)
        #expect(clean["logs"]?.string?.contains("topsecret1") == false)
    }
}
