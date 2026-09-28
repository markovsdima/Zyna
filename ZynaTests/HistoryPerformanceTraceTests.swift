//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Compact history performance diagnostics", .serialized)
struct HistoryPerformanceTraceTests {
    @Test("One summary aggregates phases, errors, scroll gaps and counts without identifiers")
    func summary() throws {
        let database = AccountDatabase(try DatabaseQueue())
        let clock = Atomic<TimeInterval>(0)
        let lines = Atomic<[String]>([])
        let trace = HistoryPerformanceTrace.Session(roomID: "!private-room:example.org", database: database,
            interval: nil, clock: { clock.wrappedValue }, output: { line in lines.modify { $0.append(line) } })
        defer { trace.stop() }
        trace.sampledView()
        let operation = trace.begin(.sdk)
        clock.wrappedValue = 2
        operation?.move(to: .inspect)
        clock.wrappedValue = 3
        operation?.finish(failed: true)
        operation?.finish() // Completion callbacks may race cleanup.
        trace.count(.pageRaw, 50)
        trace.count(.pageShown, 2)
        trace.gauge(.rows, 200)
        trace.scrolling(frames: 100, gaps32: 5, gaps100: 1, maximum: 0.2)
        trace.flush()
        let reports = lines.wrappedValue.filter { $0.contains("seq=") }
        #expect(reports.count == 2)
        #expect(reports[0].contains("viewAgeMs=3000"))
        #expect(reports[0].contains("pageRaw=50 pageShown=2"))
        #expect(reports[1].contains("sdk=1/2000/2000/0"))
        #expect(reports[1].contains("inspect=1/1000/1000/1"))
        #expect(reports[1].contains("gap32=5 gap100=1 maxMs=200"))
        #expect(!lines.wrappedValue.joined().contains("private-room"))
        trace.flush()
        #expect(lines.wrappedValue.filter { $0.contains("seq=") }.count == 2)
    }

    @Test("An unfinished call reports its age without fabricating completions")
    func pendingAcrossWindows() throws {
        let database = AccountDatabase(try DatabaseQueue())
        let clock = Atomic<TimeInterval>(0)
        let lines = Atomic<[String]>([])
        let trace = HistoryPerformanceTrace.Session(roomID: "!room", database: database,
            interval: nil, clock: { clock.wrappedValue }, output: { line in lines.modify { $0.append(line) } })
        defer { trace.stop() }
        let operation = trace.begin(.sdk)
        clock.wrappedValue = 10
        trace.flush()
        #expect(lines.wrappedValue.contains { $0.contains("pending[sdk=1:10000ms]") })
        clock.wrappedValue = 20
        trace.flush()
        #expect(lines.wrappedValue.contains { $0.contains("pending[sdk=1:20000ms]") })
        operation?.finish()
        trace.flush()
        #expect(lines.wrappedValue.contains { $0.contains("sdk=1/20000/20000/0") })
    }

    @Test("Backlog and output size stay bounded, even with thousands of overlapping operations")
    func bounded() throws {
        let database = AccountDatabase(try DatabaseQueue())
        let lines = Atomic<[String]>([])
        let trace = HistoryPerformanceTrace.Session(roomID: "!room", database: database,
            interval: nil, output: { line in lines.modify { $0.append(line) } })
        defer { trace.stop() }
        let operations = (0..<10_000).compactMap { _ in trace.begin(.writerQueue) }
        #expect(operations.count == 128)
        trace.flush()
        let reports = lines.wrappedValue.filter { $0.contains("seq=") }
        #expect(reports.count == 2)
        #expect(reports[0].contains("overflow=9872"))
        #expect(reports[0].contains("pending[writeQ=128:"))
        #expect(reports.joined().count < 1000)
        for operation in operations { operation.finish() }
    }

    @Test("Concurrent writers aggregate once and never log on their hot path")
    func concurrent() async throws {
        let database = AccountDatabase(try DatabaseQueue())
        let lines = Atomic<[String]>([])
        let trace = HistoryPerformanceTrace.Session(roomID: "!room", database: database,
            interval: nil, output: { line in lines.modify { $0.append(line) } })
        defer { trace.stop() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<100 {
                        let operation = trace.begin(.readWait)
                        operation?.move(to: .read)
                        trace.count(.diffs)
                        operation?.finish()
                    }
                }
            }
        }
        #expect(lines.wrappedValue.filter { $0.contains("seq=") }.isEmpty)
        trace.flush()
        #expect(lines.wrappedValue.contains { $0.contains("diffs=800") })
        #expect(lines.wrappedValue.contains { $0.contains("dbR=800/") })
    }

    @Test("Account matching and stopped sessions reject late operations")
    func accountScope() throws {
        let alice = AccountDatabase(try DatabaseQueue())
        let bob = AccountDatabase(try DatabaseQueue())
        let trace = try #require(HistoryPerformanceTrace.start(roomID: "!same-room", database: alice, forceEnabled: true))
        #expect(HistoryPerformanceTrace.capture(database: alice) === trace)
        #expect(HistoryPerformanceTrace.capture(database: bob) == nil)
        let old = trace.begin(.inspect)
        let next = try #require(HistoryPerformanceTrace.start(roomID: "!same-room", database: bob, forceEnabled: true))
        defer { next.stop() }
        old?.finish()
        #expect(trace.begin(.write) == nil)
        #expect(HistoryPerformanceTrace.capture(database: alice) == nil)
        #expect(HistoryPerformanceTrace.capture(database: bob) === next)
    }

    @Test("Instrumented database calls preserve results and issue no diagnostic SQL")
    @MainActor
    func databaseCalls() async throws {
        let database = AccountDatabase(try DatabaseQueue())
        let queries = Atomic(0)
        let lines = Atomic<[String]>([])
        try await database.write { db in
            db.trace { event in
                if case .statement(let statement) = event, statement.sql.hasPrefix("SELECT") {
                    queries.modify { $0 += 1 }
                }
            }
        }
        let trace = try #require(HistoryPerformanceTrace.start(roomID: "!room", database: database,
            forceEnabled: true, interval: nil, output: { line in lines.modify { $0.append(line) } }))
        defer { trace.stop() }
        func syncRead() throws -> Int? {
            try database.read { try Int.fetchOne($0, sql: "SELECT 41") }
        }
        #expect(try syncRead() == 41)
        #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT 42") } == 42)
        try await database.write { try $0.execute(sql: "CREATE TABLE traceTest (id INTEGER)") }
        trace.flush()
        #expect(queries.wrappedValue == 2)
        #expect(lines.wrappedValue.contains { $0.contains("dbR=2/") })
        #expect(lines.wrappedValue.contains { $0.contains("dbW=1/") })
        #expect(lines.wrappedValue.contains { $0.contains("db.main=1/") })
    }
}
