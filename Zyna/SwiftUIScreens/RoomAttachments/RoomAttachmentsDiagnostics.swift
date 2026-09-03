//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import SwiftUI
import UIKit

private let logDiag = ScopedLog(.attachments, prefix: "[Attachments][diag]")

/// Counters the R&D screen exposes so SDK behaviour can be measured
/// without a debugger attached.
struct RoomAttachmentsDiagnostics: Equatable {

    struct RequestAggregate: Equatable {
        var count = 0
        var bytes = 0
        var totalQueueMs: Double = 0
        var totalFetchMs: Double = 0
        var totalPrepareMs: Double = 0
    }

    var filterMode = ""
    var roomEncrypted: Bool?
    var chatHistorySyncPaused = false
    var rowCount = 0
    var mediaCount = 0
    var fileCount = 0
    var pendingCount = 0
    var snapshots = 0
    var timeToFirstSnapshotMs: Double?
    var lastMapMs: Double = 0
    var maxMapMs: Double = 0
    var lastApplyMs: Double = 0
    var indexErrors = 0
    var utdResolved = 0
    var utdResolveDelaysSeconds: [Double] = []
    var retryCount = 0

    var batches = 0
    var rowsFromBatches = 0
    var lastBatchMs: Double = 0
    var totalBatchMs: Double = 0
    var zeroRowBatches = 0
    var fills = 0
    var lastFillMs: Double = 0
    var fillsEndedByTimeBudget = 0
    /// Should stay 0; the batch cap is only a safety net behind the time budget.
    var fillsEndedByBatchCap = 0
    /// Snapshots that arrived after pagination finished: the timeline's
    /// item pipeline catching up with the event cache.
    var lateSnapshotsAfterFill = 0
    var settleCapHits = 0
    /// Fill requests that arrived mid-fill and were replayed afterwards.
    var pendingFillsReplayed = 0
    /// Batches whose `paginateBackwards` produced no diff within the wait:
    /// with `.onlyMessage` that is a chunk without attachments, not a fault.
    var noDiffBatches = 0
    /// `.paginating` seen while no fill of ours was running: the chat below.
    var foreignPaginations = 0
    var hitStart = false

    var byReason: [String: RequestAggregate] = [:]
    var byTier: [String: Int] = [:]
    var tileFailures = 0
    var deferredByReason: [String: Int] = [:]

    /// Producer-level SDK call counters; see `AttachmentFetchMeter`.
    var fetchMeter = AttachmentFetchMeter.Snapshot()

    var grdbMediaCount: Int?
    var grdbUtdCount: Int?
    var onlyInGRDB: [String] = []
    var onlyInSDK: [String] = []

    mutating func recordTile(reason: String, stats: AttachmentFetchStats?) {
        guard let stats else {
            tileFailures += 1
            return
        }
        byTier[stats.tier.rawValue, default: 0] += 1
        guard stats.tier == .sdk else { return }
        var aggregate = byReason[reason, default: RequestAggregate()]
        aggregate.count += 1
        aggregate.bytes += stats.bytes
        aggregate.totalQueueMs += stats.queueMs
        aggregate.totalFetchMs += stats.fetchMs
        aggregate.totalPrepareMs += stats.prepareMs
        byReason[reason] = aggregate
    }

    var lines: [String] {
        var lines: [String] = []
        lines.append(
            "filter=\(filterMode) encrypted=\(roomEncrypted.map(String.init) ?? "?") "
            + "chatSyncPaused=\(chatHistorySyncPaused)"
        )
        lines.append("rows=\(rowCount) media=\(mediaCount) files=\(fileCount) utd=\(pendingCount)")
        lines.append(
            "snapshots=\(snapshots) firstMs=\(timeToFirstSnapshotMs.map { String(format: "%.0f", $0) } ?? "-") "
            + "map=\(String(format: "%.1f", lastMapMs))/max \(String(format: "%.1f", maxMapMs))ms "
            + "apply=\(String(format: "%.1f", lastApplyMs))ms idxErr=\(indexErrors)"
        )
        lines.append(
            "batches=\(batches) rows+=\(rowsFromBatches) zero=\(zeroRowBatches) "
            + "last=\(String(format: "%.0f", lastBatchMs))ms total=\(String(format: "%.0f", totalBatchMs))ms "
            + "hitStart=\(hitStart) noDiff=\(noDiffBatches) foreign≥\(foreignPaginations)"
        )
        lines.append(
            "fills=\(fills) last=\(String(format: "%.0f", lastFillMs))ms "
            + "byBudget=\(fillsEndedByTimeBudget) byBatchCap=\(fillsEndedByBatchCap) "
            + "lateSnapshots=\(lateSnapshotsAfterFill) settleCap=\(settleCapHits)"
        )
        let delays = utdResolveDelaysSeconds.suffix(5).map { String(format: "%.0fs", $0) }.joined(separator: ",")
        lines.append("utdResolved=\(utdResolved) [\(delays)] retries=\(retryCount)")
        let tiers = byTier.keys.sorted().map { "\($0)=\(byTier[$0] ?? 0)" }.joined(separator: " ")
        lines.append("tiles: \(tiers) failed=\(tileFailures)  (sdk = calls into SDK, cache/network unknown)")
        for reason in byReason.keys.sorted() {
            guard let aggregate = byReason[reason], aggregate.count > 0 else { continue }
            let avgQueue = aggregate.totalQueueMs / Double(aggregate.count)
            let avgFetch = aggregate.totalFetchMs / Double(aggregate.count)
            let avgPrepare = aggregate.totalPrepareMs / Double(aggregate.count)
            let avgKB = Double(aggregate.bytes) / Double(aggregate.count) / 1024
            lines.append(
                "  \(reason): n=\(aggregate.count) avg=\(String(format: "%.0f", avgKB))KB "
                + "queue=\(String(format: "%.0f", avgQueue))ms fetch=\(String(format: "%.0f", avgFetch))ms "
                + "prep=\(String(format: "%.0f", avgPrepare))ms"
            )
        }
        let deferred = deferredByReason.keys.sorted().map { "\($0)=\(deferredByReason[$0] ?? 0)" }.joined(separator: " ")
        lines.append("deferred: \(deferred)")
        lines.append(
            "sdk calls (producer): total=\(fetchMeter.totalCalls) inFlight=\(fetchMeter.inFlight) "
            + "skippedNoDemand=\(fetchMeter.skippedNoDemand)"
        )
        for label in fetchMeter.byRequest.keys.sorted() {
            guard let entry = fetchMeter.byRequest[label], entry.calls > 0 else { continue }
            let avgMs = entry.averageMs
            lines.append(
                "  \(label): n=\(entry.calls) fail=\(entry.failures) "
                + "bytes=\(String(format: "%.0f", Double(entry.bytes) / 1024))KB avg=\(String(format: "%.0f", avgMs))ms"
            )
        }
        lines.append(
            "grdb: media=\(grdbMediaCount.map(String.init) ?? "-") utd=\(grdbUtdCount.map(String.init) ?? "-") "
            + "onlyGRDB=\(onlyInGRDB.count) onlySDK=\(onlyInSDK.count)"
        )
        return lines
    }
}

struct RoomAttachmentsDiagnosticsPanel: View {

    @ObservedObject var viewModel: RoomAttachmentsViewModel
    @State private var pauseChatHistorySync = AttachmentsResearchSettings.isChatHistorySyncPaused
    @State private var useAllFilter = AttachmentsResearchSettings.filterMode == .allWithSwiftFilter

    private static let thresholds: [UInt64] = [
        2 * 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024, 20 * 1024 * 1024, UInt64.max
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(viewModel.diagnostics.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Button("Threshold \(thresholdLabel)") { cycleThreshold() }
                Button("GRDB check") { viewModel.refreshGRDBCrossCheck() }
                Button("Retry keys") { viewModel.retryDecryption(reason: "diag") }
            }
            .font(.system(size: 11))
            HStack(spacing: 12) {
                Button("Refresh") { viewModel.refreshResearchDiagnostics() }
                Button("Reset SDK counters") { viewModel.resetFetchMeter() }
                Button("Log") { dumpToConsole() }
                Button("Probe missing") { viewModel.probeMissingAttachments() }
                Button("Test patch 2") { viewModel.probeEncryptedThumbnailNormalization() }
                Button("Copy") { UIPasteboard.general.string = viewModel.diagnostics.lines.joined(separator: "\n") }
            }
            .font(.system(size: 11))
            Toggle("Pause chat history sync (two-way: cancels or restarts the chat's sync below)", isOn: $pauseChatHistorySync)
                .font(.system(size: 11))
                .onChange(of: pauseChatHistorySync) { _, value in
                    AttachmentsResearchSettings.isChatHistorySyncPaused = value
                }
            Toggle("Use `.all` filter instead of `.onlyMessage` (applies on next open)", isOn: $useAllFilter)
                .font(.system(size: 11))
                .onChange(of: useAllFilter) { _, value in
                    AttachmentsResearchSettings.filterMode = value ? .allWithSwiftFilter : .sdkOnlyMessage
                }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }

    /// Same content as the panel, as `[Attachments][diag]` lines, so a
    /// console capture carries the state next to the event log.
    private func dumpToConsole() {
        viewModel.refreshResearchDiagnostics()
        logDiag("---- panel room=\(viewModel.roomId) ----")
        for line in viewModel.diagnostics.lines {
            logDiag(line)
        }
    }

    private var thresholdLabel: String {
        let threshold = viewModel.fullFileThreshold
        if threshold == UInt64.max { return "∞" }
        return "\(threshold / (1024 * 1024))MB"
    }

    private func cycleThreshold() {
        let current = Self.thresholds.firstIndex(of: viewModel.fullFileThreshold) ?? 0
        viewModel.fullFileThreshold = Self.thresholds[(current + 1) % Self.thresholds.count]
    }
}
#endif
