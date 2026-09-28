//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import MatrixRustSDK

/// Compare successful inspection with the existing timeline, without fetching
/// history, retrying decryption, or writing a partial message projection.
actor MessageProjectionDiagnostics {
    typealias Lookup = @Sendable (String) async throws -> EventTimelineItem
    private let roomID: String
    private let trace: HistoryPerformanceTrace.Session
    private let lookup: Lookup?
    private var sampled: [String: String] = [:]
    private var reportedCap = false
    private var recheckScheduled = false
    private var paginationRecheckReady = false
    private static let limit = 32

    init(roomID: String, trace: HistoryPerformanceTrace.Session, lookup: Lookup?) {
        self.roomID = roomID
        self.trace = trace
        self.lookup = lookup
    }

    func record(_ inspection: RoomTimelineEventInspection, requestedID: String) async {
        guard !Task.isCancelled, inspection.disposition == .visible,
              inspection.decryptionFailure == nil,
              inspection.event.roomId == roomID, inspection.event.eventId == requestedID,
              let sender = inspection.event.sender,
              sampled[requestedID] == nil else { return }
        guard sampled.count < Self.limit else {
            if !reportedCap { trace.count(.projectionCapped); reportedCap = true }
            return
        }
        guard ChatEventVisibility.exclusion(for: inspection) == nil else { return }
        sampled[requestedID] = sender
        await recordLookup(eventID: requestedID, sender: sender, recheck: paginationRecheckReady)
    }

    /// The first samples may precede pagination of their events. Revisit the
    /// bounded sample once, independently of repair's persisted retry delay.
    /// This is a later snapshot, not a guarantee that all SDK tasks drained.
    func recheckAfterPagination(delay: Duration = .seconds(3)) async {
        guard !recheckScheduled, !Task.isCancelled else { return }
        recheckScheduled = true
        do { try await Task.sleep(for: delay) } catch { return }
        paginationRecheckReady = true
        let snapshot = sampled
        for (eventID, sender) in snapshot.sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled else { return }
            await recordLookup(eventID: eventID, sender: sender, recheck: true)
        }
    }

    private func recordLookup(eventID: String, sender: String, recheck: Bool) async {
        func count(_ value: HistoryPerformanceTrace.Count) {
            trace.count(recheck ? Self.recheckCount(value) : value)
        }
        guard let lookup else { count(.projectionNoTimeline); return }
        guard let span = trace.begin(.projectionLookup) else { return }
        defer { span.finish() }
        do {
            let event = try await lookup(eventID)
            guard !Task.isCancelled else { return }
            guard case .eventId(let actualID) = event.eventOrTransactionId,
                  actualID == eventID, event.sender == sender else {
                count(.projectionMismatch)
                return
            }
            count(TimelineService.messageDiagnosticProjection(event))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if case ClientError.Generic(let message, _) = error,
               message == "Item with given event ID not found" {
                count(.projectionAbsent)
            } else {
                count(.projectionError)
                span.finish(failed: true)
            }
        }
    }

    private static func recheckCount(_ value: HistoryPerformanceTrace.Count) -> HistoryPerformanceTrace.Count {
        switch value {
        case .projectionUTD: return .projectionRecheckUTD
        case .projectionMapped: return .projectionRecheckMapped
        case .projectionFiltered: return .projectionRecheckFiltered
        case .projectionRedacted: return .projectionRecheckRedacted
        case .projectionParseError: return .projectionRecheckParseError
        case .projectionAbsent: return .projectionRecheckAbsent
        case .projectionError: return .projectionRecheckError
        case .projectionMismatch: return .projectionRecheckMismatch
        case .projectionNoTimeline: return .projectionRecheckNoTimeline
        default: preconditionFailure("Unexpected projection diagnostic count")
        }
    }
}
#endif
