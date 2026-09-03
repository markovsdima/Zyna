//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import MatrixRustSDK
import QuartzCore
import UIKit

private let log = ScopedLog(.attachments, prefix: "[Attachments][auto]")

/// Headless run of the attachments pipeline against one room with a
/// PASS/FAIL report in the console. Enabled by `ZYNA_ATTACHMENTS_AUTODIAG=1`
/// in the scheme; while it is on, tapping a chat runs this instead of
/// opening the chat. Temporary research tooling.
///
/// What it exercises: the fill loop (with a tab switch mid-fill), GRDB
/// coverage, the real tile loader on the first 12 visual items, the size
/// threshold with one forced original, the viewer lane limit, the cache
/// generation guard and teardown.
@MainActor
enum AttachmentsAutoDiagnostics {

    private struct Check {
        let name: String
        let passed: Bool?
        let detail: String
    }

    private static var isRunning = false

    static func run(room: Room) async {
        guard !isRunning else {
            log("run ignored: a diagnostics run is already in progress (it resets the meter and bumps the cache generation)")
            return
        }
        isRunning = true
        defer { isRunning = false }
        log("NOTE: this run downloads real media — up to 12 thumbnail files, 6 originals for the viewer lane check and one forced original of up to 8 MiB")
        var checks: [Check] = []
        let started = CACurrentMediaTime()
        let filterMode = AttachmentsResearchSettings.filterMode
        let tilePixelSize = RoomAttachmentsMetrics.tilePixelSize()
        log("==== start room=\(room.id()) filter=\(filterMode.rawValue) tilePx=\(tilePixelSize) ====")
        AttachmentFetchMeter.shared.reset()

        // 1. Fill, with a visible sentinel and a tab switch while it runs.
        let viewModel = RoomAttachmentsViewModel(room: room, filterMode: filterMode, tilePixelSize: tilePixelSize)
        await viewModel.start()
        viewModel.sentinelAppeared()
        viewModel.tab = .files

        let fillsDone = await waitUntil(seconds: 90) {
            !viewModel.isFillActive && viewModel.diagnostics.fills >= 1
        }
        var d = viewModel.diagnostics
        checks.append(Check(
            name: "fill completes",
            passed: fillsDone,
            detail: "fills=\(d.fills) batches=\(d.batches) rows=\(d.rowCount) media=\(d.mediaCount) files=\(d.fileCount) "
                + "utd=\(d.pendingCount) hitStart=\(d.hitStart) byBudget=\(d.fillsEndedByTimeBudget) "
                + "lateSnapshots=\(d.lateSnapshotsAfterFill) settleCap=\(d.settleCapHits) "
                + "foreign≥\(d.foreignPaginations) ms=\(elapsedMs(since: started))"
        ))
        checks.append(Check(
            name: "tab switch mid-fill replayed",
            passed: d.pendingFillsReplayed >= 1,
            detail: "replayed=\(d.pendingFillsReplayed)"
        ))
        checks.append(Check(name: "no diff index errors", passed: d.indexErrors == 0, detail: "indexErrors=\(d.indexErrors)"))

        // 2. GRDB coverage, meaningful only once the room start was reached.
        viewModel.refreshGRDBCrossCheck()
        let grdbDone = await waitUntil(seconds: 5) { viewModel.diagnostics.grdbMediaCount != nil }
        d = viewModel.diagnostics
        let sdkTotal = d.mediaCount + d.fileCount
        let grdbDetail = "grdb=\(d.grdbMediaCount.map(String.init) ?? "-") sdk=\(sdkTotal) "
            + "onlyGRDB=\(d.onlyInGRDB.count) onlySDK=\(d.onlyInSDK.count) grdbUtd=\(d.grdbUtdCount.map(String.init) ?? "-")"
        let mirrorEmpty = (d.grdbMediaCount ?? 0) == 0 && (d.grdbUtdCount ?? 0) == 0
        if !d.hitStart {
            checks.append(Check(name: "GRDB coverage (room start not reached)", passed: nil, detail: grdbDetail))
        } else if mirrorEmpty {
            // The mirror is only built by the chat screen's live timeline;
            // in this mode the chat is never opened, so after a relogin
            // there is nothing to compare against yet.
            checks.append(Check(name: "GRDB coverage (chat mirror empty, chat not opened since relogin)", passed: nil, detail: grdbDetail))
        } else {
            checks.append(Check(
                name: "GRDB coverage matches",
                passed: grdbDone && d.onlyInGRDB.isEmpty && d.onlyInSDK.isEmpty,
                detail: grdbDetail
            ))
        }

        // 3. Tiles: first 12 visual items through the real plan + loader, 4 at a time.
        let visual = viewModel.media.flatMap(\.items)
        let sample = Array(visual.prefix(12))
        var tiers: [String: Int] = [:]
        var deferred: [String: Int] = [:]
        var failedTiles = 0
        for chunk in stride(from: 0, to: sample.count, by: 4).map({ Array(sample[$0..<min($0 + 4, sample.count)]) }) {
            let results = await withTaskGroup(
                of: (AttachmentItem, AttachmentThumbnailPlan, AttachmentThumbnail?).self,
                returning: [(AttachmentItem, AttachmentThumbnailPlan, AttachmentThumbnail?)].self
            ) { group in
                for item in chunk {
                    let plan = viewModel.plan(for: item)
                    group.addTask {
                        guard let request = plan.request else { return (item, plan, nil) }
                        let result = await MediaCache.shared.loadAttachmentThumbnail(request, tilePixelSize: tilePixelSize)
                        return (item, plan, result)
                    }
                }
                var collected: [(AttachmentItem, AttachmentThumbnailPlan, AttachmentThumbnail?)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            for (item, plan, result) in results {
                switch plan {
                case .deferred(let reason):
                    deferred[reason.rawValue, default: 0] += 1
                case .fetch(_, let reason):
                    if let result {
                        tiers[result.stats.tier.rawValue, default: 0] += 1
                        log(
                            "tile \(reason.rawValue) tier=\(result.stats.tier.rawValue) bytes=\(result.stats.bytes) "
                            + "queue=\(ms(result.stats.queueMs)) fetch=\(ms(result.stats.fetchMs)) event=\(item.id)"
                        )
                    } else {
                        failedTiles += 1
                        log("tile \(reason.rawValue) FAILED event=\(item.id)")
                    }
                }
            }
        }
        let tierText = tiers.keys.sorted().map { "\($0)=\(tiers[$0] ?? 0)" }.joined(separator: " ")
        let deferredText = deferred.keys.sorted().map { "\($0)=\(deferred[$0] ?? 0)" }.joined(separator: " ")
        checks.append(Check(
            name: "tiles load",
            passed: sample.isEmpty ? nil : failedTiles == 0,
            detail: "sample=\(sample.count) tiers[\(tierText)] deferred[\(deferredText)] failed=\(failedTiles)"
        ))

        // 4. Threshold: deferred originals, and one forced load of the smallest.
        let tooLarge = visual.filter { viewModel.plan(for: $0) == .deferred(.tooLarge) }
            .sorted { ($0.sizeBytes ?? .max) < ($1.sizeBytes ?? .max) }
        if let candidate = tooLarge.first, let size = candidate.sizeBytes, size <= 8 * 1024 * 1024 {
            let plan = AttachmentThumbnailPlan.make(
                for: candidate, tilePixelSize: tilePixelSize,
                fullFileThreshold: viewModel.fullFileThreshold, forceLoad: true
            )
            var passed = false
            var detail = "deferred=\(tooLarge.count) forced=\(candidate.id) size=\(size)"
            if let request = plan.request {
                let result = await MediaCache.shared.loadAttachmentThumbnail(request, tilePixelSize: tilePixelSize)
                passed = result != nil
                if let stats = result?.stats {
                    detail += " tier=\(stats.tier.rawValue) bytes=\(stats.bytes) queue=\(ms(stats.queueMs)) fetch=\(ms(stats.fetchMs))"
                }
            }
            checks.append(Check(name: "tap-to-load original", passed: passed, detail: detail))
        } else {
            checks.append(Check(
                name: "tap-to-load original",
                passed: nil,
                detail: "deferred=\(tooLarge.count) (none ≤ 8 MiB to force)"
            ))
        }

        // 5. Viewer lane: up to 6 concurrent originals must never exceed 2 in flight.
        let originals = visual.filter { $0.kind == .image }
            .sorted { ($0.sizeBytes ?? .max) < ($1.sizeBytes ?? .max) }
            .prefix(6)
        if !originals.isEmpty {
            let sampler = Task<Int, Never> {
                var maxInFlight = 0
                while !Task.isCancelled {
                    maxInFlight = max(maxInFlight, AttachmentFetchMeter.shared.current().inFlight)
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return maxInFlight
            }
            let loadStart = CACurrentMediaTime()
            var loaded = 0
            var failed = 0
            await withTaskGroup(of: Bool.self) { group in
                for item in originals {
                    group.addTask {
                        (try? await MediaCache.shared.loadFullContent(source: item.source)) != nil
                    }
                }
                for await ok in group {
                    if ok { loaded += 1 } else { failed += 1 }
                }
            }
            sampler.cancel()
            let maxInFlight = await sampler.value
            checks.append(Check(
                name: "viewer lane ≤ 2 in flight",
                passed: maxInFlight <= 2 && failed == 0,
                detail: "requested=\(originals.count) loaded=\(loaded) failed=\(failed) maxInFlight=\(maxInFlight) ms=\(elapsedMs(since: loadStart))"
            ))
        }

        // 6. Cache generation: a producer that finishes after activate/clearAll must not publish.
        if let item = visual.first(where: { viewModel.plan(for: $0).request != nil }),
           let request = viewModel.plan(for: item).request {
            let cache = MediaCache.shared
            cache.debugEvictMemory()
            cache.debugBeforePublishHook = { MediaCache.shared.debugBumpCacheGeneration() }
            let stale = await cache.loadAttachmentThumbnail(request, tilePixelSize: tilePixelSize)
            cache.debugBeforePublishHook = nil
            let notInMemory = cache.cachedAttachmentThumbnail(mxc: request.mxc, tilePixelSize: tilePixelSize) == nil
            let fresh = await cache.loadAttachmentThumbnail(request, tilePixelSize: tilePixelSize)
            checks.append(Check(
                name: "stale generation is dropped",
                passed: stale == nil && notInMemory && fresh != nil,
                detail: "staleResult=\(stale == nil ? "nil" : "published!") memoryAfterStale=\(notInMemory ? "empty" : "has entry") "
                    + "reload=\(fresh.map { $0.stats.tier.rawValue } ?? "nil")"
            ))
        }

        // 7. Teardown.
        viewModel.stop()
        checks.append(Check(name: "teardown", passed: !viewModel.isFillActive, detail: "stopped; expect `deinit room=` right after this report"))

        // Report.
        log("---- report room=\(room.id()) elapsed=\(elapsedMs(since: started)) ----")
        for check in checks {
            let mark = check.passed.map { $0 ? "PASS" : "FAIL" } ?? "SKIP"
            log("\(mark) \(check.name) — \(check.detail)")
        }
        let failures = checks.filter { $0.passed == false }.count
        let passes = checks.filter { $0.passed == true }.count
        log("==== \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED") (\(passes) passed, \(checks.count - passes - failures) skipped) ====")
        viewModel.refreshResearchDiagnostics()
        for line in viewModel.diagnostics.lines {
            log("panel: \(line)")
        }
    }

    // MARK: - Helpers

    private static func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func elapsedMs(since start: CFTimeInterval) -> String {
        ms((CACurrentMediaTime() - start) * 1000)
    }

    private static func ms(_ value: Double) -> String {
        "\(String(format: "%.0f", value))ms"
    }
}
#endif
