//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG && GLASS_PROFILING
import UIKit

/// Opt-in scroll diagnostics, compiled with DEBUG && GLASS_PROFILING.
/// Sample on main; summarize off-main once per three seconds.
/// No per-frame logging or additional display link.
final class GlassCaptureProfiler {
    static let shared = GlassCaptureProfiler()
    private static let log = ScopedLog(.glassPerf, prefix: "GLASSPERF")

    private struct Capture {
        var totalMs = 0.0
        var portalMs = 0.0
        var sourceMs = 0.0
        var portals = 0
        var gradientDraws = 0
        var otherDraws = 0
        var imageDraws = 0
        var cacheBuilds = 0
        var cacheBuildMs = 0.0
        var prepareMs = 0.0
        var treeMs = 0.0
        var finishMs = 0.0
        var pixels = 0
    }

    private struct Tick {
        let id: Int
        let start: CFTimeInterval
        let target: CFTimeInterval
        let duration: CFTimeInterval
        var totalMs = 0.0
        var captureMs = 0.0
        var renderCPUMs = 0.0
        var drawableMs = 0.0
        var busy = false
        var captureCount = 0
        var failedCaptures = 0
        var failedRenders = 0
        var captures: [ObjectIdentifier: CaptureSpan] = [:]
        var busyRenderers: Set<ObjectIdentifier> = []
    }

    private struct CaptureSpan {
        let start: CFTimeInterval
        var end: CFTimeInterval
    }

    struct Submission {
        let batchID: Int
        let commandID: Int
    }

    private struct BusyCheck {
        let tickID: Int
        let time: CFTimeInterval
        let needsCapture: Bool
    }

    private struct Completion {
        let gpuStart: CFTimeInterval
        let gpuEnd: CFTimeInterval
        let callback: CFTimeInterval
        let released: CFTimeInterval

        var isValid: Bool {
            gpuStart > 0 && gpuEnd >= gpuStart && callback >= gpuEnd && released >= callback
        }

        func stage(at time: CFTimeInterval, commit: CFTimeInterval) -> String {
            guard isValid, commit > 0, time >= commit, time < released else { return "unknown" }
            if time < gpuStart { return "waitingGPU" }
            if time < gpuEnd { return "executingGPU" }
            if time < callback { return "completionDelivery" }
            return "mainQueue"
        }
    }

    private struct Command {
        let tickID: Int
        let tickStart: CFTimeInterval
        let target: CFTimeInterval
        let duration: CFTimeInterval
        let capture: CaptureSpan?
        let ready: CFTimeInterval
        var refreshesBlur = false
        var queued = false
        var discarded = false
        var commit: CFTimeInterval = 0
        var completion: Completion?
        var nextCapture: CFTimeInterval?
        var busyChecks: [BusyCheck] = []
    }

    private struct Batch {
        let id: Int
        let start: CFTimeInterval
        let environment: String
        var ticks: [Tick] = []
        var captures: [String: [Capture]] = [:]
        var periodsMs: [Double] = []
        var gapsMs: [Double] = []
        var gpuMs: [Double] = []
        var gpuToCallbackMs: [Double] = []
        var callbackToMainMs: [Double] = []
        var commands: [Int: Command] = [:]
        var untrackedBusyChecks = 0
        var queuedRenderCPUMs: [Double] = []
        var queuedDrawableMs: [Double] = []
        var failedQueuedRenders = 0
    }

    private var batch: Batch?
    private var nextID = 0
    private var lastScrollTime: CFTimeInterval = 0
    private var previousFrameTimestamp: CFTimeInterval?
    private var tick: Tick?
    private var capture: Capture?
    private var captureStart: CFTimeInterval = 0
    private var capturePhaseStart: CFTimeInterval = 0
    private var captureRendererID: ObjectIdentifier?

    func noteScroll() {
        guard LogConfig.enabled.contains(.glassPerf) else { return }
        let now = CACurrentMediaTime()
        if now - lastScrollTime > 0.25 { previousFrameTimestamp = nil }
        lastScrollTime = now
        guard batch == nil else { return }
        nextID += 1
        let process = ProcessInfo.processInfo
        batch = Batch(
            id: nextID, start: now,
            environment: "iOS=\(UIDevice.current.systemVersion) thermal=\(process.thermalState.rawValue)"
                + " lowPower=\(process.isLowPowerModeEnabled) build=Debug"
                + " gradientCache=\(BubbleGradientCanvasView.captureImageCacheEnabled)"
                + " captureOverlap=\(GlassRenderer.captureOverlapEnabled)"
        )
        let id = nextID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.flush(id: id)
        }
    }

    func beginTick(_ frame: DisplayLinkDriver.Frame) {
        guard batch != nil, LogConfig.enabled.contains(.glassPerf) else { return }
        let now = CACurrentMediaTime()
        guard now - lastScrollTime <= 0.25 else { return }
        tick = Tick(id: (batch?.ticks.count ?? 0) + 1, start: now,
                    target: frame.targetTimestamp, duration: frame.duration)
        batch?.periodsMs.append(frame.duration * 1000)
        if let previousFrameTimestamp {
            batch?.gapsMs.append((frame.timestamp - previousFrameTimestamp) * 1000)
        }
        previousFrameTimestamp = frame.timestamp
    }

    func endTick() {
        guard var sample = tick else { return }
        sample.totalMs = (CACurrentMediaTime() - sample.start) * 1000
        batch?.ticks.append(sample)
        tick = nil
    }

    func rendererBusy(_ renderer: GlassRenderer, needsCapture: Bool) {
        guard tick != nil else { return }
        tick?.busy = true
        // Nav and input share a renderer: count one check per renderer/tick.
        guard tick?.busyRenderers.insert(ObjectIdentifier(renderer)).inserted == true else { return }
        guard let submission = renderer.profileSubmission, batch?.id == submission.batchID,
              batch?.commands[submission.commandID] != nil, let tick else {
            batch?.untrackedBusyChecks += 1
            return
        }
        batch?.commands[submission.commandID]?.busyChecks.append(
            BusyCheck(tickID: tick.id, time: CACurrentMediaTime(), needsCapture: needsCapture)
        )
    }

    func beginCapture(renderer: GlassRenderer) {
        guard tick != nil else { return }
        capture = Capture()
        captureStart = CACurrentMediaTime()
        capturePhaseStart = captureStart
        captureRendererID = ObjectIdentifier(renderer)
        if let submission = renderer.profileSubmission, batch?.id == submission.batchID,
           batch?.commands[submission.commandID]?.nextCapture == nil {
            batch?.commands[submission.commandID]?.nextCapture = captureStart
        }
    }

    func beginCaptureTree() {
        guard capture != nil else { return }
        let now = CACurrentMediaTime()
        capture?.prepareMs = (now - capturePhaseStart) * 1000
        capturePhaseStart = now
    }

    func endCaptureTree() {
        guard capture != nil else { return }
        let now = CACurrentMediaTime()
        capture?.treeMs = (now - capturePhaseStart) * 1000
        capturePhaseStart = now
    }

    func endCapture(name: String, width: Int?, height: Int?) {
        guard var sample = capture else { return }
        let now = CACurrentMediaTime()
        sample.totalMs = (now - captureStart) * 1000
        sample.finishMs = (now - capturePhaseStart) * 1000
        sample.pixels = (width ?? 0) * (height ?? 0)
        tick?.captureMs += sample.totalMs
        tick?.captureCount += 1
        if width == nil { tick?.failedCaptures += 1 }
        batch?.captures[name, default: []].append(sample)
        if let captureRendererID {
            let start = tick?.captures[captureRendererID]?.start ?? captureStart
            tick?.captures[captureRendererID] = CaptureSpan(start: start, end: now)
        }
        capture = nil
        captureRendererID = nil
    }

    func captureTimer() -> CFTimeInterval? {
        capture == nil ? nil : CACurrentMediaTime()
    }

    func endPortal(since start: CFTimeInterval?) {
        guard let start else { return }
        capture?.portalMs += (CACurrentMediaTime() - start) * 1000
        capture?.portals += 1
    }

    func endSourceRender(since start: CFTimeInterval, isGradient: Bool, cachedImage: Bool) {
        capture?.sourceMs += (CACurrentMediaTime() - start) * 1000
        if isGradient { capture?.gradientDraws += 1 } else { capture?.otherDraws += 1 }
        if cachedImage { capture?.imageDraws += 1 }
    }

    func endCacheBuild(since start: CFTimeInterval?) {
        guard let start else { return }
        capture?.cacheBuildMs += (CACurrentMediaTime() - start) * 1000
        capture?.cacheBuilds += 1
    }

    func renderTimer() -> CFTimeInterval? {
        tick == nil ? nil : CACurrentMediaTime()
    }

    func submissionTimer(_ submission: Submission?) -> CFTimeInterval? {
        guard let submission, batch?.id == submission.batchID,
              LogConfig.enabled.contains(.glassPerf) else { return nil }
        return CACurrentMediaTime()
    }

    func endRender(since start: CFTimeInterval?, result: GlassRenderer.BatchBreakdown?) {
        guard let start else { return }
        tick?.renderCPUMs += (CACurrentMediaTime() - start) * 1000
        tick?.drawableMs += result?.drawableMs ?? 0
        if result == nil || result?.skippedReason != nil { tick?.failedRenders += 1 }
    }

    func prepareSubmission(renderer: GlassRenderer) -> Submission? {
        guard let tick, let batchID = batch?.id else { return nil }
        let commandID = (batch?.commands.count ?? 0) + 1
        batch?.commands[commandID] = Command(
            tickID: tick.id, tickStart: tick.start, target: tick.target, duration: tick.duration,
            capture: tick.captures[ObjectIdentifier(renderer)], ready: CACurrentMediaTime()
        )
        return Submission(batchID: batchID, commandID: commandID)
    }

    func queueSubmission(_ submission: Submission?) {
        guard let submission, batch?.id == submission.batchID else { return }
        batch?.commands[submission.commandID]?.queued = true
    }

    func discardSubmission(_ submission: Submission?) {
        guard let submission, batch?.id == submission.batchID else { return }
        batch?.commands[submission.commandID]?.discarded = true
    }

    func setRefreshesBlur(_ submission: Submission?, _ refreshes: Bool) {
        guard let submission, batch?.id == submission.batchID else { return }
        batch?.commands[submission.commandID]?.refreshesBlur = refreshes
    }

    func endQueuedRender(
        _ submission: Submission?, since start: CFTimeInterval?,
        result: GlassRenderer.BatchBreakdown?
    ) {
        guard let start, let submission, batch?.id == submission.batchID else { return }
        batch?.queuedRenderCPUMs.append((CACurrentMediaTime() - start) * 1000)
        batch?.queuedDrawableMs.append(result?.drawableMs ?? 0)
        if result == nil { batch?.failedQueuedRenders += 1 }
    }

    func willCommit(_ submission: Submission?) {
        guard let submission, batch?.id == submission.batchID else { return }
        batch?.commands[submission.commandID]?.commit = CACurrentMediaTime()
    }

    func completeSubmission(
        _ submission: Submission?, gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval,
        callback: CFTimeInterval, released: CFTimeInterval
    ) {
        // Completion can arrive after the batch was emitted. Do not attribute
        // the old GPU work to a new scroll; gpuN reports accepted samples.
        guard let submission, batch?.id == submission.batchID else { return }
        let completion = Completion(gpuStart: gpuStart, gpuEnd: gpuEnd,
                                    callback: callback, released: released)
        batch?.commands[submission.commandID]?.completion = completion
        guard completion.isValid else { return }
        batch?.gpuMs.append((gpuEnd - gpuStart) * 1000)
        batch?.gpuToCallbackMs.append((callback - gpuEnd) * 1000)
        batch?.callbackToMainMs.append((released - callback) * 1000)
    }

    private func flush(id: Int) {
        guard let completed = batch, completed.id == id else { return }
        batch = nil
        previousFrameTimestamp = nil
        guard !completed.ticks.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            Self.report(completed)
        }
    }

    private static func report(_ batch: Batch) {
        func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
        func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "-" }
            let sorted = values.sorted()
            let p95 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
            return "\(fmt(values.reduce(0, +) / Double(values.count)))/\(fmt(p95))/\(fmt(sorted.last!))"
        }
        let ticks = batch.ticks
        let prefix = "#\(batch.id)"
        let span = (ticks.last?.start ?? batch.start) - batch.start
        let captureTicks = ticks.filter { $0.captureCount > 0 }.count
        let busyTicks = ticks.filter(\.busy).count
        let lateEntry = ticks.filter { $0.start >= $0.target }.count
        let pastTarget = ticks.filter { $0.start + $0.totalMs / 1000 > $0.target }.count
        log("\(prefix) \(batch.environment) spanSec=\(fmt(span)) ticks=\(ticks.count)"
            + " captureTicks=\(captureTicks) busyTicks=\(busyTicks)"
            + " failedCaptures=\(ticks.reduce(0) { $0 + $1.failedCaptures })"
            + " failedRenders=\(ticks.reduce(0) { $0 + $1.failedRenders })")
        log("\(prefix) timing=avg/p95/max_ms period=\(summary(batch.periodsMs))"
            + " callbackGap=\(summary(batch.gapsMs)) lateEntry=\(lateEntry) pastTarget=\(pastTarget)"
            + " (callback cadence, not displayed FPS)")
        log("\(prefix) cpuTick=\(summary(ticks.map(\.totalMs)))"
            + " captureSum=\(summary(ticks.map(\.captureMs)))"
            + " renderCPU=\(summary(ticks.map(\.renderCPUMs)))"
            + " drawableWait=\(summary(ticks.map(\.drawableMs)))"
            + " gpu=\(summary(batch.gpuMs)) gpuN=\(batch.gpuMs.count)"
            + " gpuToCallback=\(summary(batch.gpuToCallbackMs))"
            + " callbackToMain=\(summary(batch.callbackToMainMs))")
        reportPipeline(batch, summary: summary, fmt: fmt)
        for name in batch.captures.keys.sorted() {
            let samples = batch.captures[name]!
            let total = samples.reduce(0) { $0 + $1.totalMs }
            let source = samples.reduce(0) { $0 + $1.sourceMs }
            log("\(prefix) bar=\(name) n=\(samples.count)"
                + " capture=\(summary(samples.map(\.totalMs)))"
                + " prepare=\(summary(samples.map(\.prepareMs)))"
                + " tree=\(summary(samples.map(\.treeMs)))"
                + " finish=\(summary(samples.map(\.finishMs)))"
                + " portal=\(summary(samples.map(\.portalMs)))"
                + " sourceRender=\(summary(samples.map(\.sourceMs)))"
                + " sourcePct=\(fmt(total > 0 ? source / total * 100 : 0))"
                + " portalsPerCapture=\(fmt(Double(samples.reduce(0) { $0 + $1.portals }) / Double(samples.count)))"
                + " gradientDraws=\(samples.reduce(0) { $0 + $1.gradientDraws })"
                + " otherDraws=\(samples.reduce(0) { $0 + $1.otherDraws })"
                + " imageDraws=\(samples.reduce(0) { $0 + $1.imageDraws })"
                + " cacheBuilds=\(samples.reduce(0) { $0 + $1.cacheBuilds })"
                + " cacheBuildTotalMs=\(fmt(samples.reduce(0) { $0 + $1.cacheBuildMs }))"
                + " captureMPix=\(fmt(Double(samples.reduce(0) { $0 + $1.pixels }) / Double(samples.count) / 1_000_000))")
        }
    }

    private static func reportPipeline(
        _ batch: Batch, summary: ([Double]) -> String, fmt: (Double) -> String
    ) {
        let ordered = batch.commands.sorted { $0.key < $1.key }
        let completed = ordered.map(\.value).filter { $0.completion?.isValid == true && $0.commit > 0 }
        log("#\(batch.id) overlap submitted=\(ordered.filter { $0.value.commit > 0 }.count)"
            + " queued=\(ordered.filter { $0.value.queued }.count)"
            + " discarded=\(ordered.filter { $0.value.discarded }.count)"
            + " queuedRenderN=\(batch.queuedRenderCPUMs.count)"
            + " queuedRenderCPU=\(summary(batch.queuedRenderCPUMs))"
            + " queuedDrawableWait=\(summary(batch.queuedDrawableMs))"
            + " failedQueuedRenders=\(batch.failedQueuedRenders)")
        for captures in [true, false] {
            let samples = completed.filter { ($0.capture != nil) == captures }
            guard !samples.isEmpty else { continue }
            func times(_ value: (Command, Completion) -> Double) -> String {
                summary(samples.map { value($0, $0.completion!) * 1000 })
            }
            // All intervals in this line belong to the same commands.
            log("#\(batch.id) pipeline=\(captures ? "capture" : "renderOnly") n=\(samples.count)"
                + " blurN=\(samples.filter(\.refreshesBlur).count)"
                + " cpuToCommit=\(times { command, _ in command.commit - command.tickStart })"
                + " readyToCommit=\(times { command, _ in command.commit - command.ready })"
                + " submitToGPU=\(times { $1.gpuStart - $0.commit })"
                + " gpu=\(times { $1.gpuEnd - $1.gpuStart })"
                + " tickToGPUend=\(times { $1.gpuEnd - $0.tickStart })"
                + " tickToRelease=\(times { $1.released - $0.tickStart })"
                + " gpuPastTarget=\(samples.filter { $0.completion!.gpuEnd > $0.target }.count)"
                + " releaseOverPeriod=\(samples.filter { $0.completion!.released - $0.tickStart > $0.duration }.count)")
        }

        var stages: [String: Int] = [:]
        var captureChecks = 0
        var remainingGPU: [Double] = []
        var remainingRelease: [Double] = []
        for (_, command) in ordered {
            for check in command.busyChecks {
                let stage = command.completion?.stage(at: check.time, commit: command.commit) ?? "unknown"
                stages[stage, default: 0] += 1
                if check.needsCapture { captureChecks += 1 }
                if let end = command.completion, end.isValid {
                    remainingGPU.append(max(0, end.gpuEnd - check.time) * 1000)
                    remainingRelease.append(max(0, end.released - check.time) * 1000)
                }
            }
        }
        // Keep idle periods out. Overlap is counted separately so resumption
        // gaps remain nonnegative and comparable with the serial baseline.
        let resumed = completed.filter {
            if let next = $0.nextCapture {
                return next >= $0.completion!.released && $0.busyChecks.contains { $0.needsCapture }
            }
            return false
        }
        let overlapping = completed.filter { ($0.nextCapture ?? .infinity) < $0.completion!.gpuEnd }
        let resumeGaps = resumed.map { ($0.nextCapture! - $0.completion!.released) * 1000 }
        log("#\(batch.id) busyChecks=\(stages.values.reduce(0, +)) captureChecks=\(captureChecks)"
            + " waitingGPU=\(stages["waitingGPU", default: 0])"
            + " executingGPU=\(stages["executingGPU", default: 0])"
            + " completionDelivery=\(stages["completionDelivery", default: 0])"
            + " mainQueue=\(stages["mainQueue", default: 0])"
            + " unknown=\(stages["unknown", default: 0]) untracked=\(batch.untrackedBusyChecks)"
            + " remainingGPU=\(summary(remainingGPU)) remainingRelease=\(summary(remainingRelease))"
            + " releaseToNextCapture=\(summary(resumeGaps)) resumeN=\(resumed.count)"
            + " captureBeforeGPUend=\(overlapping.count)"
            + " pendingCommands=\(ordered.filter { $0.value.completion == nil && !$0.value.discarded }.count)")

        let captured = ordered.filter { $0.value.capture != nil && $0.value.completion?.isValid == true }
        let examples = Array(captured.filter { !$0.value.busyChecks.isEmpty }.prefix(2))
            + Array(captured.filter { $0.value.busyChecks.isEmpty }.prefix(1))
        for (id, command) in examples {
            func offset(_ time: CFTimeInterval?) -> String {
                time.map { fmt(($0 - command.tickStart) * 1000) } ?? "-"
            }
            let end = command.completion!
            let checks = command.busyChecks.prefix(4).map {
                "\($0.tickID):\(offset($0.time)):\(end.stage(at: $0.time, commit: command.commit))"
            }.joined(separator: ",")
            log("#\(batch.id) frame=\(command.tickID) cmd=\(id) t_ms_from_tick=0"
                + " target=\(offset(command.target))"
                + " capture=\(offset(command.capture?.start))..\(offset(command.capture?.end))"
                + " commit=\(offset(command.commit)) gpu=\(offset(end.gpuStart))..\(offset(end.gpuEnd))"
                + " callback=\(offset(end.callback)) release=\(offset(end.released))"
                + " nextCapture=\(offset(command.nextCapture)) busy=[\(checks)]")
        }
    }
}
#endif
