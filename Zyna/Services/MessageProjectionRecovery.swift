//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// Owned by the serial repair task. Inspection can decrypt an event without
/// updating the SDK timeline. Request its ordinary redecryption/diff path;
/// never turn raw inspection JSON into a partial stored message.
struct MessageProjectionRecovery {
    struct SDK: Sendable {
        let session: @Sendable (_ eventID: String, _ sender: String) async throws -> String?
        let retry: @Sendable ([String]) -> Void

        init(session: @escaping @Sendable (String, String) async throws -> String?,
             retry: @escaping @Sendable ([String]) -> Void) {
            self.session = session
            self.retry = retry
        }

        init(timeline: Timeline) {
            session = { eventID, sender in
                let event = try await timeline.getEventTimelineItemByEventId(eventId: eventID)
                guard case .eventId(let actualID) = event.eventOrTransactionId,
                      actualID == eventID, event.sender == sender,
                      case .msgLike(let content) = event.content,
                      case .unableToDecrypt(let failure) = content.kind,
                      case .megolmV1AesSha2(let sessionID, _) = failure,
                      !sessionID.isEmpty else { return nil }
                return sessionID
            }
            retry = { timeline.retryDecryption(sessionIds: $0) }
        }
    }

    private var cursor: MessageDecryptionRepairStore.ProjectionCursor?
    private var nextScan: TimeInterval = 0
    private var nextRetry: TimeInterval = 0
    private var lastRetry: TimeInterval?
    private var attempts = 0

    mutating func retryManually() {
        cursor = nil
        nextScan = 0
        attempts = 0
        // Repeated button taps cannot flood the SDK's room-wide retry queue.
        nextRetry = lastRetry.map { $0 + 15 } ?? 0
    }

    mutating func run(roomID: String, database: AccountDatabase, sdk: SDK,
                      clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async throws {
        let now = clock()
        try Task.checkCancellation()
        guard database.isActive, now >= nextScan, now >= nextRetry else { return }
        nextScan = now + 5
        let after = cursor
        let page = try await database.read {
            try MessageDecryptionRepairStore.projectionPage(in: $0, roomID: roomID, after: after)
        }
        // Walk bounded pages even when early rows have no keys or are absent
        // from the live timeline. Such rows must not starve later candidates.
        cursor = page.count == 16 ? page.last?.cursor : nil
        if page.isEmpty, after == nil { attempts = 0 }
        var sessions = Set<String>()
        for candidate in page where candidate.isProjection {
            try Task.checkCancellation()
            guard database.isActive else { return }
            do {
                if let session = try await sdk.session(candidate.eventID, candidate.sender), !session.isEmpty {
                    sessions.insert(session)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // An event can still be outside the loaded timeline. Keep
                // the durable queue intact and revisit it on a later pass.
            }
        }
        try Task.checkCancellation()
        guard database.isActive, !sessions.isEmpty else { return }
        // The SDK bounds work to the supplied sessions. Still coalesce and
        // back off across the worker while awaiting asynchronous projections.
        sdk.retry(sessions.sorted())
        let dispatchedAt = clock()
        lastRetry = dispatchedAt
        nextRetry = dispatchedAt + min(300, 15 * pow(2, Double(min(attempts, 5))))
        attempts += 1
        #if DEBUG
        let trace = HistoryPerformanceTrace.capture(database: database)
        trace?.count(.projectionRetry)
        trace?.count(.projectionRetrySessions, sessions.count)
        #endif
    }
}
