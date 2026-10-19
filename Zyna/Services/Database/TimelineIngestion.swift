//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

extension TimelineDiffBatcher {
    /// Limits the prepared Swift representation, not SDK buffers or total RSS.
    /// One indivisible event may exceed the byte target and gets its own batch.
    struct IngestionLimits {
        var maximumEvents = 256
        var maximumEstimatedBytes = 1024 * 1024
        var maximumDelay: TimeInterval = 0.05
    }

    /// A single owner lets the writer release its payload BEFORE returning its
    /// permit. Capturing an immutable array in a queued block would retain it
    /// until after the next producer has been allowed to run.
    final class WritePayload: @unchecked Sendable {
        var events: [[DiffOp]] = []
        let estimatedBytes: Int

        init(taking events: inout [[DiffOp]], estimatedBytes: Int) {
            swap(&self.events, &events)
            self.estimatedBytes = estimatedBytes
        }
    }

    static func estimatedBytes(of operations: [DiffOp]) -> Int {
        // Conservative accounting for owned values. Shared/inline strings may
        // be counted more than once; allocator rounding and SDK storage aren't
        // included. Do not serialize JSON or use reflection on the hot path.
        var bytes = 64 + MemoryLayout<DiffOp>.stride * operations.count
        for operation in operations {
            switch operation {
            case .liveArrival: break
            case .deleteAttachment(let id), .inspectDecryption(let id):
                bytes += id.utf8.count
            case .delete(let id, let eventID):
                bytes += id.utf8.count + (eventID?.utf8.count ?? 0)
            case .upsert(let row, _, let profile):
                bytes += row.timelinePayloadBytes
                if case .ready(let name) = profile { bytes += name?.utf8.count ?? 0 }
            case .upsertMatrixRTCCall(let row):
                bytes += stringBytes([row.notificationEventId, row.roomId, row.parentEventId,
                    row.senderId, row.senderDisplayName, row.notificationType, row.callIntent,
                    row.declinedByJSON, row.outcome])
            case .upsertMatrixRTCMembership(let row):
                bytes += stringBytes([row.eventId, row.roomId, row.eventType, row.stateKey,
                    row.senderId, row.userId, row.deviceId, row.memberId, row.callIntent])
            }
        }
        return bytes
    }

    fileprivate static func stringBytes(_ strings: [String?]) -> Int {
        strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
    }
}

private extension StoredMessage {
    var timelinePayloadBytes: Int {
        TimelineDiffBatcher.stringBytes([
            id, roomId, eventId, transactionId, senderId, senderDisplayName, senderAvatarUrl,
            contentType, contentBody, contentFormat, contentFormattedBody, contentPollJSON,
            contentMediaJSON, contentCaption, contentFilename, contentMimetype, contentBlurhash,
            contentThumbnailMediaJSON, contentThumbnailMimetype, reactionsJSON, sendStatus,
            replyEventId, replySenderId, replySenderName, replyBody, latestEditEventId,
            editTransactionId, pendingEditBody, pendingEditFormattedBody,
            pendingEditZynaAttributesJSON, zynaAttributesJSON
        ]) + (contentVoiceWaveform?.count ?? 0)
    }
}

#if DEBUG
/// Scalar counters only: no event IDs, bodies, per-event logs or retained SDK
/// objects. Input counts include the currently processed callback because its
/// original arrays remain alive until that callback's mapping completes.
final class TimelineIngestionMetrics: @unchecked Sendable {
    struct Input {
        var diffs = 0
        var items = 0
        var resets = 0
        var sets = 0

        init(_ diffs: [TimelineDiff]) {
            self.diffs = diffs.count
            for diff in diffs {
                switch diff {
                case .reset(let values): items += values.count; resets += 1
                case .append(let values): items += values.count
                case .set: items += 1; sets += 1
                case .pushFront, .pushBack, .insert: items += 1
                default: break
                }
            }
        }
    }

    struct Snapshot {
        var rawBatches = 0
        var rawDiffs = 0
        var rawItems = 0
        var peakRawBatches = 0
        var peakRawDiffs = 0
        var peakRawItems = 0
        var receivedItems = 0
        var resets = 0
        var sets = 0
        var mappedEvents = 0
        var mappedBytes = 0
        var peakMappedEvents = 0
        var peakMappedBytes = 0
        var mappedTotal = 0
        var completedBatches = 0
        var failedBatches = 0

        var description: String {
            "rawBatches=\(rawBatches) rawDiffs=\(rawDiffs) rawItems=\(rawItems) "
                + "peakRawBatches=\(peakRawBatches) peakRawDiffs=\(peakRawDiffs) peakRawItems=\(peakRawItems) "
                + "receivedItems=\(receivedItems) resets=\(resets) sets=\(sets) "
                + "mappedEvents=\(mappedEvents) mappedBytes=\(mappedBytes) peakMappedEvents=\(peakMappedEvents) "
                + "peakMappedBytes=\(peakMappedBytes) mappedTotal=\(mappedTotal) "
                + "completedBatches=\(completedBatches) failedBatches=\(failedBatches)"
        }
    }

    private struct State {
        var snapshot = Snapshot()
        var lastLog: TimeInterval = 0
        var lastReportedTotal = 0
        var reportedWhileBusy = false
    }
    private let state = Atomic(State())
    private static let logsEnabled = ProcessInfo.processInfo.environment["ZYNA_TIMELINE_INGEST_TRACE"] == "1"
    private static let reporting = DispatchQueue(label: "com.zyna.timeline-ingestion-metrics", qos: .utility)
    private let id = String(UUID().uuidString.prefix(8))

    var snapshot: Snapshot { state.withValue { $0.snapshot } }

    func receive(_ input: Input) {
        state.modify {
            $0.snapshot.rawBatches += 1
            $0.snapshot.rawDiffs += input.diffs
            $0.snapshot.rawItems += input.items
            $0.snapshot.receivedItems += input.items
            $0.snapshot.resets += input.resets
            $0.snapshot.sets += input.sets
            $0.snapshot.peakRawBatches = max($0.snapshot.peakRawBatches, $0.snapshot.rawBatches)
            $0.snapshot.peakRawDiffs = max($0.snapshot.peakRawDiffs, $0.snapshot.rawDiffs)
            $0.snapshot.peakRawItems = max($0.snapshot.peakRawItems, $0.snapshot.rawItems)
        }
        reportIfNeeded()
    }

    func release(_ input: Input) {
        state.modify {
            $0.snapshot.rawBatches -= 1
            $0.snapshot.rawDiffs -= input.diffs
            $0.snapshot.rawItems -= input.items
        }
        reportIfNeeded()
    }

    func mapped(bytes: Int) {
        state.modify {
            $0.snapshot.mappedEvents += 1
            $0.snapshot.mappedBytes += bytes
            $0.snapshot.mappedTotal += 1
            $0.snapshot.peakMappedEvents = max($0.snapshot.peakMappedEvents, $0.snapshot.mappedEvents)
            $0.snapshot.peakMappedBytes = max($0.snapshot.peakMappedBytes, $0.snapshot.mappedBytes)
        }
    }

    func releaseMapped(count: Int, bytes: Int, failed: Bool) {
        state.modify {
            $0.snapshot.mappedEvents -= count
            $0.snapshot.mappedBytes -= bytes
            $0.snapshot.completedBatches += 1
            if failed { $0.snapshot.failedBatches += 1 }
        }
        reportIfNeeded()
    }

    private func reportIfNeeded() {
        guard Self.logsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let value = state.withValue { state -> Snapshot? in
            let idle = state.snapshot.rawBatches == 0 && state.snapshot.mappedEvents == 0
            let finishedBurst = idle && (state.reportedWhileBusy
                || state.snapshot.mappedTotal - state.lastReportedTotal >= 256)
            guard finishedBurst || now - state.lastLog >= 10 else { return nil }
            state.lastLog = now
            state.lastReportedTotal = state.snapshot.mappedTotal
            state.reportedWhileBusy = !idle
            return state.snapshot
        }
        guard let value else { return }
        Self.reporting.async { [id] in print("[TimelineIngest] session=\(id) \(value.description)") }
    }
}
#endif
