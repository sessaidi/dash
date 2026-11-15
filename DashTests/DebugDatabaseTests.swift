import Foundation
import SQLite3
import Testing
@testable import Dash

/// Debug › Database: read-only browsing, secrets hidden.
struct DebugDatabaseTests {
    @Test func browsesReadOnlyAndHidesSecrets() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "debug-db-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE ZNOTE(Z_PK INTEGER, ZTITLE TEXT); INSERT INTO ZNOTE VALUES (1, 'Hello'), (2, 'token ghp_abcdefghijklmnopqrstuvwxyz0123456789'); CREATE TABLE ZSTOREDSECRET(Z_PK INTEGER, ZVALUE BLOB);", nil, nil, nil)
        sqlite3_close(db)

        let database = try DebugDatabase(url: url)
        #expect(database.tables().map(\.name) == ["ZNOTE"])
        #expect(database.tables().first?.rows == 2)
        let rows = database.rows(of: "ZNOTE")
        #expect(rows.columns == ["Z_PK", "ZTITLE"] && rows.values.first == ["1", "Hello"])
        #expect(rows.values.last?.last?.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789") == false)
        #expect(database.rows(of: "ZNOTE", filter: "hello").values.count == 1)
        #expect(database.run("DELETE FROM ZNOTE").error != nil)
        #expect(database.run("SELECT * FROM ZSTOREDSECRET").error != nil)
        #expect(database.run("SELECT z.ZVALUE FROM ZNOTE n JOIN ZSTOREDSECRET z ON z.Z_PK = n.Z_PK").error != nil)
        #expect(database.rows(of: "ZSTOREDSECRET").error != nil)
        // Words that merely look like secret table names are fine.
        #expect(database.run("SELECT * FROM ZNOTE WHERE ZTITLE LIKE '%secret%'").error == nil)
        #expect(database.run("ATTACH DATABASE ':memory:' AS other").error != nil)
    }

    @Test func filtersAcrossTheWholeTable() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "debug-db-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE ZITEM(Z_PK INTEGER, ZNAME TEXT); WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500) INSERT INTO ZITEM SELECT i, 'item ' || i FROM n; UPDATE ZITEM SET ZNAME = 'needle_1%' WHERE Z_PK = 450;", nil, nil, nil)
        sqlite3_close(db)

        let database = try DebugDatabase(url: url)
        #expect(database.rows(of: "ZITEM", filter: "needle").values.map { $0[0] } == ["450"])
        #expect(database.rows(of: "ZITEM", filter: "_1%").values.count == 1)
        #expect(database.rows(of: "ZITEM", limit: 200, offset: 400).values.count == 100)
    }

    @Test func aFileThatWontOpenThrows() {
        #expect(throws: (any Error).self) { try DebugDatabase(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).sqlite")) }
    }
}
