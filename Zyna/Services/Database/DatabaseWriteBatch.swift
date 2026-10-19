//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Yields the shared connection between bounded transactions. Each element
/// is an indivisible domain update, including all of its derived records.
/// Call from a serial worker to preserve ordering across batches.
enum DatabaseWriteBatch {
    struct Limits {
        var maximumCount = 64
        var maximumDuration: TimeInterval = 0.025
    }

    /// A failed chunk rolls back as a whole. Earlier chunks remain committed
    /// and have already been reported through `didCommit`. The caller owns
    /// recovery of the remaining suffix; this method never retries writes.
    static func write<Element>(
        _ elements: [Element], to database: AccountDatabase, source: String,
        limits: Limits = Limits(),
        prepare: (Database) throws -> Void = { _ in },
        apply: (Database, Element) throws -> Void,
        finish: (Database, Range<Int>) throws -> Void = { _, _ in },
        didCommit: (Range<Int>) -> Void = { _ in }
    ) throws {
        precondition(limits.maximumCount > 0 && limits.maximumDuration > 0)
        var lowerBound = 0
        #if DEBUG
        let context = PollCacheDiagnostics.isEnabled
            ? "db=\(PollCacheDiagnostics.databaseKey(database.path)) source=\(source) batch=\(UUID().uuidString.prefix(8))" : ""
        let batchBegan = ProcessInfo.processInfo.systemUptime
        var committedChunks = 0
        var completed = false
        defer {
            PollCacheDiagnostics.log("writer-batch-end \(context) total=\(elements.count) committed=\(lowerBound) chunks=\(committedChunks) totalMs=\(PollCacheDiagnostics.milliseconds(since: batchBegan)) result=\(completed ? "success" : "failed")")
        }
        #endif
        // Even an empty batch may carry a read receipt or other metadata.
        repeat {
            var upperBound = lowerBound
            #if DEBUG
            let requested = ProcessInfo.processInfo.systemUptime
            var transactionBegan = requested
            var workMs = 0
            #endif
            try database.write { db in
                let started = ProcessInfo.processInfo.systemUptime
                #if DEBUG
                transactionBegan = started
                PollCacheDiagnostics.log("writer-begin \(context) offset=\(lowerBound) total=\(elements.count) waitMs=\(Int((started - requested) * 1000))")
                defer { workMs = PollCacheDiagnostics.milliseconds(since: started) }
                #endif
                try prepare(db)
                while upperBound < elements.count {
                    try apply(db, elements[upperBound])
                    upperBound += 1
                    if upperBound - lowerBound >= limits.maximumCount
                        || ProcessInfo.processInfo.systemUptime - started >= limits.maximumDuration {
                        break
                    }
                }
                try finish(db, lowerBound..<upperBound)
            }
            #if DEBUG
            committedChunks += 1
            PollCacheDiagnostics.log("writer-end \(context) offset=\(lowerBound) count=\(upperBound - lowerBound) workMs=\(workMs) transactionMs=\(PollCacheDiagnostics.milliseconds(since: transactionBegan))")
            #endif
            didCommit(lowerBound..<upperBound)
            lowerBound = upperBound
        } while lowerBound < elements.count
        #if DEBUG
        completed = true
        #endif
    }
}
