import Foundation
import Testing
@_spi(DashHost) @testable import DashKit

/// Fixes from the SDK audit: secrets, numbers, list comparisons, text search, dates, reports.
@MainActor
@Suite(.serialized)
struct AuditFixesTests {
    @Test func secretNamesAreJudgedOnWholeParts() {
        for name in ["account_password", "service_account_token", "refresh_tokens", "access_tokens", "client_secret", "API_KEY", "password"] {
            #expect(Sanitizer.isSecretName(name), "\(name)")
        }
        for name in ["token_count", "max_tokens", "output_tokens", "author", "account", "accounts", "authored_at"] {
            #expect(!Sanitizer.isSecretName(name), "\(name)")
        }
        #expect(Sanitizer.clean("plain text with nothing secret") == "plain text with nothing secret")
    }

    @Test func hugeNumbersNeverTrap() async throws {
        #expect(DashDate.number(1e19) == "1e+19" && DashDate.number(42) == "42" && DashDate.number(1.5) == "1.5")
        let dataset = QueryDataset(name: "rows", summary: "") { _ in [["n": .number(1e19)], ["n": 2]] }
        let engine = QueryEngine(datasets: [dataset])
        #expect(try await engine.run("from rows | take 99999999999999999999").rows.count == 2)
        #expect(try await engine.run("from rows | where n > 10").rows.count == 1)
    }

    @Test func listsAndFreeText() async throws {
        let dataset = QueryDataset(name: "rows", summary: "") { _ in
            [["name": "a", "labels": ["bug", "ui"]], ["name": "b", "labels": ["debug"]], ["name": "c", "labels": []]]
        }
        let engine = QueryEngine(datasets: [dataset])
        let names = { (query: String) in try await engine.run(query).rows.compactMap { $0["name"]?.string } }
        #expect(try await names("from rows | where labels != bug") == ["b", "c"])
        #expect(try await names("from rows | where labels !~ bug") == ["c"])
        // Free text matches values, not field names.
        #expect(try await names("rows labels").isEmpty)
        #expect(try await names("rows debug") == ["b"])
    }

    @Test func datesAndTimeZones() {
        #expect(DashDate.parse("2024-01-02T03:04:05.000+0000") == Date(timeIntervalSince1970: 1_704_164_645))
        #expect(DashDate.parse("2026-11-10T09:30:00Z") != nil)
        let local = DashDate.parse("2026-10-12 14:00")
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 14))
        #expect(local == expected)
        #expect(DashDate.parse(.number(1_700_000_000_000)) == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func corruptSecretsFileIsNeverOverwritten() throws {
        let saved = (Keychain.backend, Keychain.fileURL)
        defer { (Keychain.backend, Keychain.fileURL) = saved }
        let url = FileManager.default.temporaryDirectory.appending(path: "dash-secrets-\(UUID().uuidString).json")
        Keychain.fileURL = url
        #expect(Keychain.write("one", for: "a", in: .file) && Keychain.write("two", for: "b", in: .file))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try Data("{ not json".utf8).write(to: url)
        #expect(!Keychain.write("three", for: "c", in: .file))
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test func connectionHostsAreWholeDomains() {
        let connection = IntegrationConnection(baseURL: URL(string: "https://www.googleapis.com")!, hosts: ["googleapis.com"])
        #expect(connection.allows(URL(string: "https://logging.googleapis.com/v2")!))
        #expect(connection.allows(URL(string: "https://googleapis.com/x")!))
        #expect(!connection.allows(URL(string: "https://evilgoogleapis.com/x")!))
    }

    @Test func reportsAndChoicesSurviveBadData() throws {
        let report = try AgentReport.parse(#"{"summary":"x","findings":[{"severity":"nonsense"}]}"#, agentID: "a", startedAt: .now, reason: "t")
        #expect(report.status == .failed)
        let choice = try JSONDecoder().decode(AITaskChoice.self, from: Data(#"{"model":"claude-retired-1","templates":{"t":"kept"}}"#.utf8))
        #expect(choice.model == nil && choice.templates["t"] == "kept")
    }
}
