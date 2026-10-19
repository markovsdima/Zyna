//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Database contention diagnostics", .enabled(if: PollCacheDiagnostics.isEnabled))
struct DatabaseDiagnosticsTests {
    @Test("A synchronous read reports its caller without SQL values")
    @MainActor
    func synchronousReadCaller() throws {
        let database = try DatabaseQueue()
        let output = Atomic<[String]>([])
        database.writeWithoutTransaction { db in
            PollCacheDiagnostics.traceDatabase(db, path: database.path, slowThreshold: 0, includeCallStacks: true) { entry in
                output.modify { $0.append(entry) }
            }
        }

        let sql = "SELECT 'private-message-body'"
        let result = try database.read { db in try String.fetchOne(db, sql: sql) }
        #expect(result == "private-message-body")
        let entries = output.wrappedValue
        let transaction = try #require(entries.first { $0.contains("db-slow-transaction") })
        #expect(transaction.contains("access=read"))
        #expect(transaction.contains("SELECT:\(PollCacheDiagnostics.key(sql))"))
        #expect(transaction.contains("completion=COMMIT"))
        #expect(entries.contains { $0.contains("db-slow-caller") && $0.contains("synchronousReadCaller") })
        #expect(!entries.contains { $0.contains("private-message-body") })
    }

    @Test("Rollback and the next transaction keep separate bounded fingerprints")
    func rollbackAndNextTransaction() throws {
        let database = try DatabaseQueue()
        try database.write { db in try db.execute(sql: "CREATE TABLE sample (body TEXT)") }
        let output = Atomic<[String]>([])
        database.writeWithoutTransaction { db in
            PollCacheDiagnostics.traceDatabase(db, path: database.path, slowThreshold: 0) { entry in
                output.modify { $0.append(entry) }
            }
        }
        #expect(throws: ProbeError.self) {
            try database.write { db in
                for index in 0..<12 {
                    try db.execute(sql: "INSERT INTO sample VALUES (?)", arguments: ["private-\(index)"])
                }
                throw ProbeError.rollback
            }
        }
        let count = try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample") }
        #expect(count == 0)
        let entries = output.wrappedValue
        let transactions = entries.filter { $0.contains("db-slow-transaction") }
        #expect(transactions.count == 2)
        let rollback = try #require(transactions.first)
        #expect(rollback.contains("tx=1 "))
        #expect(rollback.contains("access=write-capable"))
        #expect(rollback.contains("statements=12 "))
        #expect(rollback.contains("completion=ROLLBACK"))
        #expect(rollback.components(separatedBy: "INSERT:").count - 1 == 8)
        let read = try #require(transactions.last)
        #expect(read.contains("tx=2 "))
        #expect(read.contains("access=read"))
        #expect(!read.contains("INSERT:"))
        #expect(!entries.contains { $0.contains("db-slow-caller") })
        #expect(!entries.contains { $0.contains("private-") || $0.contains("INTO sample") })
    }

    private enum ProbeError: Error { case rollback }
}
#endif
