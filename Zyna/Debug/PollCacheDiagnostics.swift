//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import CryptoKit
import Foundation
import GRDB

/// Temporary, scoped tracing of poll persistence across app launches.
/// Never includes message text, answer text, or raw account/event identifiers.
enum PollCacheDiagnostics {
    private static let logger = ScopedLog(.polls, prefix: "[PollCache]")
    private static let run = String(UUID().uuidString.prefix(8))
    private static let began = ProcessInfo.processInfo.systemUptime
    static var isEnabled: Bool { LogConfig.enabled.contains(.polls) }

    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let origin = began
        logger("run=\(run) tMs=\(milliseconds(since: origin)) main=\(Thread.isMainThread) \(message())")
    }

    static func milliseconds(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    /// The iOS container prefix can change after installation. Compare the
    /// account directory and filename across launches, not that prefix.
    static func databaseKey(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return key(url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent)
    }

    struct Read<Value: Equatable & Sendable>: Equatable, Sendable {
        let value: Value
        let finished: TimeInterval

        // Timing metadata must not defeat observation deduplication.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
    }

    static func read<Value: Equatable & Sendable>(
        context: String, requestedAt: TimeInterval? = nil, fetch: () throws -> Value
    ) rethrows -> Read<Value> {
        let started = ProcessInfo.processInfo.systemUptime
        let wait = requestedAt.map { " waitMs=\(Int((started - $0) * 1000))" } ?? ""
        log("db-read-begin \(context)\(wait)")
        defer { log("db-read-end \(context) workMs=\(milliseconds(since: started))") }
        return Read(value: try fetch(), finished: ProcessInfo.processInfo.systemUptime)
    }

    /// Diagnose contention on the shared serial connection. Slow transactions
    /// include bounded SQL fingerprints and optional code symbols, never values.
    static func traceDatabase(
        _ db: Database, path: String, slowThreshold: TimeInterval = 0.1,
        includeCallStacks: Bool = false,
        report: @escaping (String) -> Void = { log($0) }
    ) {
        guard isEnabled else { return }
        let identity = databaseKey(path)
        var transactionBegan: TimeInterval?
        var transactionID = 0
        var queryOnly = false
        var statements = 0
        var fingerprints: [String] = []
        db.trace(options: .profile) { event in
            guard isEnabled, case .profile(let statement, let duration) = event else { return }
            let sql = statement.sql
            let command = sql.prefix { !$0.isWhitespace }.uppercased()
            // GRDB brackets DatabaseQueue.read with these pragmas. A COMMIT
            // alone does not distinguish a read from a write transaction.
            if sql == "PRAGMA query_only = 1" { queryOnly = true }
            if sql == "PRAGMA query_only = 0" { queryOnly = false }
            switch command {
            case "BEGIN":
                transactionBegan = ProcessInfo.processInfo.systemUptime
                transactionID += 1
                statements = 0
                fingerprints.removeAll(keepingCapacity: true)
            case "COMMIT", "END", "ROLLBACK":
                // ROLLBACK TO only undoes a savepoint, not the transaction.
                guard !sql.uppercased().hasPrefix("ROLLBACK TO") else { break }
                if let start = transactionBegan,
                   ProcessInfo.processInfo.systemUptime - start >= slowThreshold {
                    let context = "db=\(identity) tx=\(transactionID)"
                    report("db-slow-transaction \(context) ms=\(milliseconds(since: start)) access=\(queryOnly ? "read" : "write-capable") statements=\(statements) firstStatements=[\(fingerprints.joined(separator: ","))] completion=\(command) completionMs=\(Int(duration * 1000))")
                    // Capture only on slow completion. For synchronous main
                    // access, the application caller is still on this stack.
                    // Async callers may only show the worker/GRDB frames.
                    // Symbolication itself can stall this connection on a
                    // cold launch. Opt in only when identifying a caller;
                    // leave it off for subsequent timing measurements.
                    if includeCallStacks {
                        let stack = Thread.callStackSymbols
                        let appFrames = stack.filter {
                            ($0.contains("$s4Zyna") || $0.contains("$s9ZynaTests"))
                                && !$0.contains("PollCacheDiagnostics")
                        }
                        let frames = appFrames.isEmpty ? Array(stack.prefix(32)) : Array(appFrames.prefix(12))
                        for (index, frame) in frames.enumerated() {
                            report("db-slow-caller \(context) frame=\(index) \(frame)")
                        }
                    }
                }
                transactionBegan = nil
            default:
                if transactionBegan != nil {
                    statements += 1
                    if fingerprints.count < 8 {
                        // Restrict even command names to a fixed vocabulary:
                        // SQL comments and literals must not enter the log.
                        let known = ["SELECT", "INSERT", "UPDATE", "DELETE", "PRAGMA", "CREATE", "DROP", "ALTER", "WITH", "SAVEPOINT", "RELEASE"]
                        let kind = known.contains(command) ? command : "OTHER"
                        fingerprints.append("\(kind):\(key(sql))")
                    }
                }
            }
            if duration >= slowThreshold {
                report("db-slow-statement db=\(identity) ms=\(Int(duration * 1000)) query=\(key(sql))")
            }
        }
    }

    static func error(_ error: Error) -> String {
        // DatabaseError descriptions may contain SQL arguments with message text.
        if let error = error as? DatabaseError { return "sqlite:\(error.resultCode.rawValue)" }
        return "\(String(reflecting: type(of: error))):\((error as NSError).code)"
    }

    static func items(_ items: [RoomPollItem]) -> String {
        let ended = items.filter { $0.snapshot.hasEnded }.count
        let ids = items.prefix(12).map {
            "\(key($0.eventId)):\($0.snapshot.hasEnded ? "ended" : "active")"
        }.joined(separator: ",")
        return "count=\(items.count) active=\(items.count - ended) ended=\(ended) ids=[\(ids)]"
    }

    static func stored(roomId: String, eventId: String, ended: Bool, redacted: Bool, in db: Database) {
        guard isEnabled else { return }
        let detail = "room=\(key(roomId)) event=\(key(eventId)) ended=\(ended) redacted=\(redacted)"
        db.afterNextTransaction(onCommit: { _ in
            log("write-commit \(detail)")
        }, onRollback: { _ in
            log("write-rollback \(detail)")
        })
    }

    /// Enqueued on the database's serial reader before/after migration.
    /// Diagnostics must neither block main on another read nor break startup.
    static func database(_ database: DatabaseQueue, phase: String) {
        guard isEnabled else { return }
        let path = database.path
        database.asyncRead { result in
            do {
                let db = try result.get()
                let polls = try db.tableExists("roomPoll")
                    ? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM roomPoll") ?? 0 : -1
                log("database \(phase) db=\(databaseKey(path)) pollRows=\(polls)")
                if phase == "after-migrate" {
                    let journal = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
                    let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
                    let autoCheckpoint = try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint") ?? -1
                    log("db-settings db=\(databaseKey(path)) journal=\(journal) synchronous=\(synchronous) walAutoCheckpoint=\(autoCheckpoint)")
                }
            } catch {
                log("database \(phase) db=\(databaseKey(path)) error=\(self.error(error))")
            }
        }
    }
}
#endif
