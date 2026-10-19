//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import UIKit

/// Bounded, account-bound counters. No SQL, event payloads or per-event logs.
/// Durations are inclusive and may overlap; they are not CPU percentages.
enum HistoryPerformanceTrace {
    static var enabled: Bool { LogConfig.enabled.contains(.historyPerformance) }
    private static let lock = NSLock()
    private static weak var active: Session?
    private static let forcedCapture = Atomic(false)

    static func start(roomID: String, database: AccountDatabase,
                      forceEnabled: Bool = false,
                      interval: TimeInterval? = 10,
                      output: @escaping @Sendable (String) -> Void = { ScopedLog(.historyPerformance, prefix: "[HistoryPerf]")($0) }) -> Session? {
        // Tests opt in without mutating the logging configuration shared by
        // other suites. Ordinary chat sessions always use the scope setting.
        guard enabled || forceEnabled else { return nil }
        let session = Session(roomID: roomID, database: database, interval: interval, output: output)
        lock.lock()
        let previous = active
        active = session
        forcedCapture.wrappedValue = forceEnabled
        lock.unlock()
        previous?.stop()
        return session
    }

    static func capture(database: AccountDatabase) -> Session? {
        guard enabled || forcedCapture.wrappedValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let active, active.databaseID == ObjectIdentifier(database) else { return nil }
        return active
    }

    private static func release(_ session: Session) {
        lock.lock()
        defer { lock.unlock() }
        guard active === session else { return }
        active = nil
        forcedCapture.wrappedValue = false
    }

    enum Stage: String, CaseIterable {
        case sdk, mapQueue = "mapQ", map, writerQueue = "writeQ", flush
        case readWait = "dbR.wait", read = "dbR", writeWait = "dbW.wait", write = "dbW", mainDB = "db.main"
        case pageQueue = "pageQ", page, refreshQueue = "refreshQ", refresh, decode = "prepare"
        case mainQueue = "mainQ", renderMain = "render", texture
        case prepareReconcile = "prep.reconcile", prepareMessages = "prep.messages", prepareGroups = "prep.groups"
        case prepareRows = "prep.rows", prepareDiff = "prep.diff"
        case inspect, projectionLookup, repairQueue = "repairQ", repairWrite, repairPause, barrier, bounds
    }

    enum Count: String, CaseIterable {
        case demand, background, pageJoined, sdkMissing, sdkStart, diffs, upserts
        case pageRaw, pageShown, pageRedacted, pageEmpty, pageStale, pageStaleWindow, pageStalePresentation, pageError
        case refreshes, unchanged, refreshStale, refreshError, reloads, batches, inserted, deleted
        case boundsRefreshes, boundsStale
        case retentionAttempts, retentionApplied, retentionStale, retentionExhausted, retentionError
        case hidden, visible, utd, unknown, inspectError, repairChanges, repairWake, overflow
        case visibleText, visibleMedia, visiblePoll, visibleZynaCall, visibleCall, visibleOther
        case visibleEmptyText, visibleCallInvite, visibleRTC
        case unknownEncrypted, unknownOther, inspectLegacy
        case projectionUTD, projectionMapped, projectionFiltered, projectionRedacted, projectionParseError
        case projectionAbsent, projectionError, projectionMismatch, projectionNoTimeline, projectionCapped
        case projectionRecheckUTD, projectionRecheckMapped, projectionRecheckFiltered, projectionRecheckRedacted
        case projectionRecheckParseError, projectionRecheckAbsent, projectionRecheckError
        case projectionRecheckMismatch, projectionRecheckNoTimeline
        case projectionRetry, projectionRetrySessions
    }

    enum Gauge: String, CaseIterable {
        case rows, messages, localOlder, sdkBusy, localBusy, serverWait, exhausted, edgeScreens, spanDays
        case recoveryPending, recoveryKeys, recoveryProjection, recoveryFailed, recoveryUnknown
    }

    struct Timing {
        var count = 0
        var total: TimeInterval = 0
        var maximum: TimeInterval = 0
        var errors = 0
        mutating func add(_ duration: TimeInterval, failed: Bool) {
            count += 1; total += duration; maximum = max(maximum, duration)
            if failed { errors += 1 }
        }
    }

    final class Span: @unchecked Sendable {
        private let session: Session
        private let id: UInt64
        fileprivate init(session: Session, id: UInt64) { self.session = session; self.id = id }
        func move(to stage: Stage) { session.complete(id, next: stage, failed: false) }
        func finish(failed: Bool = false) { session.complete(id, next: nil, failed: failed) }
        deinit { finish() }
    }

    final class Session: @unchecked Sendable {
        let databaseID: ObjectIdentifier
        private let id = String(UUID().uuidString.prefix(8))
        private let lock = NSLock()
        private let reporting = DispatchQueue(label: "com.zyna.history-performance", qos: .utility)
        private let clock: @Sendable () -> TimeInterval
        private let output: @Sendable (String) -> Void
        private let began: TimeInterval
        private var lastReport: TimeInterval
        private var sequence = 0
        private var nextID: UInt64 = 0
        private var stopped = false
        private var pending: [UInt64: (stage: Stage, began: TimeInterval)] = [:]
        private var timings: [Stage: Timing] = [:]
        private var counts: [Count: Int] = [:]
        private var gauges: [Gauge: Int] = [:]
        private var gaugesChanged = false
        private var viewSampleAt: TimeInterval?
        private var frames = 0
        private var gaps32 = 0
        private var gaps100 = 0
        private var longestGap: TimeInterval = 0
        private var timer: DispatchSourceTimer?

        init(roomID: String, database: AccountDatabase, interval: TimeInterval? = 10,
             clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
             output: @escaping @Sendable (String) -> Void = { ScopedLog(.historyPerformance, prefix: "[HistoryPerf]")($0) }) {
            databaseID = ObjectIdentifier(database)
            self.clock = clock; self.output = output
            began = clock(); lastReport = began
            let header = "v=3 trace=\(id) begin room=\(PollCacheDiagnostics.key(roomID)) db=\(PollCacheDiagnostics.databaseKey(database.path)) intervalS=\(Int(interval ?? 0)) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) timings=n/avgMs/maxMs/errors sdkIncludesNetwork=true repairPauseMs=100"
            reporting.async { output(header) }
            if let interval {
                let timer = DispatchSource.makeTimerSource(queue: reporting)
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
                timer.setEventHandler { [weak self] in self?.flush() }
                self.timer = timer
                timer.resume()
            }
        }

        func begin(_ stage: Stage) -> Span? {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return nil }
            guard pending.count < 128 else { counts[.overflow, default: 0] += 1; return nil }
            nextID &+= 1
            pending[nextID] = (stage, clock())
            return Span(session: self, id: nextID)
        }

        fileprivate func complete(_ id: UInt64, next: Stage?, failed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, let item = pending.removeValue(forKey: id) else { return }
            let now = clock()
            timings[item.stage, default: Timing()].add(max(0, now - item.began), failed: failed)
            if let next { pending[id] = (next, now) }
        }

        func count(_ key: Count, _ amount: Int = 1) {
            guard amount != 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            if !stopped { counts[key, default: 0] += amount }
        }

        func gauge(_ key: Gauge, _ value: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, gauges[key] != value else { return }
            gauges[key] = value; gaugesChanged = true
        }

        func scrolling(frames: Int, gaps32: Int, gaps100: Int, maximum: TimeInterval) {
            guard frames > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            self.frames += frames; self.gaps32 += gaps32; self.gaps100 += gaps100
            longestGap = max(longestGap, maximum)
        }

        func sampledView() {
            lock.lock()
            defer { lock.unlock() }
            if !stopped { viewSampleAt = clock() }
        }

        /// Runs on the reporting queue in production; exposed for deterministic tests.
        func flush(ending: Bool = false) {
            lock.lock()
            let now = clock()
            guard (!stopped || ending), ending || !timings.isEmpty || !counts.isEmpty
                || !pending.isEmpty || frames > 0 || gaugesChanged else { lock.unlock(); return }
            sequence += 1
            let prefix = "trace=\(id) seq=\(sequence) tMs=\(Int((now - began) * 1000)) windowMs=\(Int((now - lastReport) * 1000))\(ending ? " end" : "")"
            let times = timings; let numbers = counts; let state = gauges
            let running = pending
            let scroll = (frames, gaps32, gaps100, longestGap)
            let viewAge = viewSampleAt.map { Int((now - $0) * 1000) } ?? -1
            timings.removeAll(keepingCapacity: true); counts.removeAll(keepingCapacity: true)
            frames = 0; gaps32 = 0; gaps100 = 0; longestGap = 0; gaugesChanged = false
            lastReport = now
            lock.unlock()

            // Formatting and logging never execute on the writer or UI thread.
            let stateText = Gauge.allCases.compactMap { key in state[key].map { "\(key.rawValue)=\($0)" } }.joined(separator: " ")
            let countText = Count.allCases.compactMap { key in numbers[key].map { "\(key.rawValue)=\($0)" } }.joined(separator: " ")
            let activeText = Stage.allCases.compactMap { stage -> String? in
                let values = running.values.filter { $0.stage == stage }
                guard let oldest = values.map(\.began).min() else { return nil }
                return "\(stage.rawValue)=\(values.count):\(Int((now - oldest) * 1000))ms"
            }.joined(separator: " ")
            output("\(prefix) power=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) viewAgeMs=\(viewAge) state[\(stateText)] n[\(countText)] pending[\(activeText)]")
            let timeText = Stage.allCases.compactMap { stage -> String? in
                guard let value = times[stage] else { return nil }
                return "\(stage.rawValue)=\(value.count)/\(Int(value.total * 1000 / Double(value.count)))/\(Int(value.maximum * 1000))/\(value.errors)"
            }.joined(separator: " ")
            output("\(prefix) ms[\(timeText)] scroll[frames=\(scroll.0) gap32=\(scroll.1) gap100=\(scroll.2) maxMs=\(Int(scroll.3 * 1000))]")
        }

        func stop() {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            stopped = true
            timer?.cancel(); timer = nil
            lock.unlock()
            HistoryPerformanceTrace.release(self)
            reporting.async { [self] in flush(ending: true) }
        }
    }
}

/// Samples only while the user scrolls. Per-frame work is scalar arithmetic;
/// aggregate transfer happens once a second, with no per-frame logging.
final class HistoryScrollSampler: NSObject {
    private var link: CADisplayLink?
    private weak var session: HistoryPerformanceTrace.Session?
    private var previous: TimeInterval = 0
    private var sent: TimeInterval = 0
    private var frames = 0
    private var gaps32 = 0
    private var gaps100 = 0
    private var maximum: TimeInterval = 0

    func start(_ session: HistoryPerformanceTrace.Session?) {
        guard link == nil, let session else { return }
        self.session = session
        previous = CACurrentMediaTime(); sent = previous
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        guard UIApplication.shared.applicationState == .active else { stop(); return }
        let gap = now - previous
        previous = now; frames += 1; maximum = max(maximum, gap)
        if gap >= 0.032 { gaps32 += 1 }
        if gap >= 0.1 { gaps100 += 1 }
        if now - sent >= 1 { transfer(); sent = now }
    }

    private func transfer() {
        session?.scrolling(frames: frames, gaps32: gaps32, gaps100: gaps100, maximum: maximum)
        frames = 0; gaps32 = 0; gaps100 = 0; maximum = 0
    }

    func stop() { link?.invalidate(); link = nil; transfer(); session = nil }
}
#endif
