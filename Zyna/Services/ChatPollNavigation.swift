//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Preparation never changes the visible window. The presenter commits it
/// synchronously, only while the requesting screen and account are current.
struct PreparedPollNavigation {
    let open: @MainActor () -> Bool
}

enum PollNavigationError: Error {
    case unavailable
    case loadingFailed
}

enum ChatPollNavigation {
    private enum Target { case ready, pending, unavailable }

    /// Keep the ordinary chat timeline continuous: discovery rows are not full
    /// messages, and inserting an isolated SDK event would create a history gap.
    @MainActor
    static func load(
        eventId: String, roomId: String, database: AccountDatabase,
        budget: Duration = .seconds(30), settle: Duration = .seconds(3),
        isCurrent: () -> Bool,
        paginate: () async -> HistoryPaginationResult
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: budget)
        var settledDeadline: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            guard isCurrent(), database.isActive else { throw CancellationError() }
            let target = try await database.read { db -> Target in
                guard let record = try StoredMessage
                    .filter(Column("roomId") == roomId && Column("eventId") == eventId).fetchOne(db)
                else { return .pending }
                if record.contentType == "poll" { return .ready }
                if record.contentType == "unableToDecrypt" { return .pending }
                if try MessageDecryptionRepairStore.isPendingLegacy(record, in: db) { return .pending }
                return .unavailable
            }
            try Task.checkCancellation()
            guard isCurrent(), database.isActive else { throw CancellationError() }
            switch target {
            case .ready: return
            case .unavailable: throw PollNavigationError.unavailable
            case .pending: break
            }
            guard ContinuousClock.now < deadline else { throw PollNavigationError.loadingFailed }
            if let settledDeadline {
                guard ContinuousClock.now < settledDeadline else { throw PollNavigationError.unavailable }
                // SDK replies can precede listener delivery/decryption. Do not
                // mistake the first drained, empty snapshot for a missing poll.
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            switch await paginate() {
            case .page(let reachedStart):
                if reachedStart { settledDeadline = ContinuousClock.now.advanced(by: settle) }
            case .cancelled: throw CancellationError()
            case .failed, .unavailable: throw PollNavigationError.loadingFailed
            }
        }
    }
}
