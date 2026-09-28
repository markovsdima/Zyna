//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Testing
@testable import Zyna

@Suite("Repair refresh coalescing")
@MainActor
struct ChatHistoryRefreshTests {
    @Test("Repair bursts use a fixed deadline and preserve every committed revision and recovered ID")
    func burst() {
        var scheduled: [() -> Void] = []
        var starts: [TimelineFlushSummary] = []
        let queue = ChatTimelineRefreshQueue(scheduleRepair: { scheduled.append($0) }) { summary, done in
            starts.append(summary)
            done(.applied)
        }
        for revision in 1...8 {
            queue.enqueueRepair(repair(revision))
        }
        #expect(starts.isEmpty)
        #expect(scheduled.count == 1)
        #expect(queue.hasPending)
        let pending = queue.summaryForApplying(.init(setCount: 1))
        #expect(!pending.allowsRemoteRedactionAnimation)
        #expect(pending.committedHistoryRevision == 8)
        scheduled[0]()
        #expect(starts.count == 1)
        #expect(starts[0].committedHistoryRevision == 8)
        #expect(starts[0].recoveredEventIDs == Set((1...8).map { "$\($0)" }))
        #expect(!queue.hasPending)
        queue.enqueueRepair(repair(9))
        #expect(scheduled.count == 2)
        scheduled[1]()
        #expect(starts.count == 2)
    }

    @Test("Live updates flush pending repairs immediately; obsolete timers cannot flush the next batch")
    func liveUpdate() {
        var scheduled: [() -> Void] = []
        var starts: [TimelineFlushSummary] = []
        let queue = ChatTimelineRefreshQueue(scheduleRepair: { scheduled.append($0) }) { summary, done in
            starts.append(summary)
            done(.applied)
        }
        queue.enqueueRepair(repair(1))
        queue.enqueue(.init(setCount: 1, redactedUpsertCount: 1))
        #expect(starts.count == 1)
        #expect(starts[0].recoveredEventIDs == ["$1"])
        #expect(!starts[0].allowsRemoteRedactionAnimation)
        queue.enqueueRepair(repair(2))
        scheduled[0]()
        #expect(starts.count == 1)
        #expect(queue.hasPending)
        scheduled[1]()
        #expect(starts.count == 2)
        queue.enqueue(.init(setCount: 1, committedHistoryRevision: 2))
        #expect(starts.last?.allowsRemoteRedactionAnimation == true)
    }

    @Test("Repairs cannot delay an already queued live update")
    func liveFollowUp() {
        var scheduled: [() -> Void] = []
        var starts: [TimelineFlushSummary] = []
        var finish: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue(scheduleRepair: { scheduled.append($0) }) { summary, done in
            starts.append(summary)
            finish = done
        }
        queue.enqueue(.init(setCount: 1))
        queue.enqueue(.init(pushBackCount: 1))
        queue.enqueueRepair(repair(1))
        #expect(scheduled.isEmpty)
        finish?(.applied)
        #expect(starts.count == 2)
        #expect(starts[1].pushBackCount == 1)
        #expect(starts[1].recoveredEventIDs == ["$1"])
        finish?(.applied)
    }

    @Test("Repair changes during a snapshot retain one follow-up, even when the timer fires while reading",
          arguments: [true, false])
    func inFlight(timerFirst: Bool) {
        var scheduled: [() -> Void] = []
        var starts: [TimelineFlushSummary] = []
        var finish: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue(scheduleRepair: { scheduled.append($0) }) { summary, done in
            starts.append(summary)
            finish = done
        }
        queue.enqueue(.init(setCount: 1))
        queue.enqueueRepair(repair(1))
        #expect(queue.summaryForApplying(starts[0]).recoveredEventIDs == ["$1"])
        if timerFirst { scheduled[0]() }
        finish?(.applied)
        #expect(starts.count == (timerFirst ? 2 : 1))
        if !timerFirst { scheduled[0]() }
        #expect(starts.count == 2)
        #expect(starts[1].committedHistoryRevision == 1)
        finish?(.applied)
        #expect(!queue.hasPending)
    }

    @Test("Closing discards a pending repair timer and preserves no cross-chat state")
    func close() {
        var scheduled: [() -> Void] = []
        let queue = ChatTimelineRefreshQueue(scheduleRepair: { scheduled.append($0) }) { _, _ in
            Issue.record("Closed chat started a repair refresh")
        }
        queue.enqueueRepair(repair(1))
        queue.cancel()
        scheduled[0]()
        queue.enqueueRepair(repair(2))
        #expect(scheduled.count == 1)
        #expect(!queue.hasPending)
    }

    @Test("A superseded live snapshot retries immediately with accumulated repair provenance")
    func supersededLive() {
        var scheduled: [() -> Void] = []
        var starts: [TimelineFlushSummary] = []
        var finish: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue(scheduleRepair: { scheduled.append($0) }) { summary, done in
            starts.append(summary)
            finish = done
        }
        queue.enqueue(.init(setCount: 1))
        queue.enqueueRepair(repair(1))
        finish?(.superseded)
        #expect(starts.count == 2)
        #expect(starts[1].setCount == 1)
        #expect(starts[1].recoveredEventIDs == ["$1"])
        finish?(.applied)
        scheduled[0]()
        #expect(starts.count == 2)
    }

    private func repair(_ revision: Int) -> TimelineFlushSummary {
        .init(committedHistoryRevision: UInt64(revision), includesUnreportedHistory: true,
              recoveredEventIDs: ["$\(revision)"])
    }

    @Test("Bounds-only cleanup remains narrow only while every merged notification is narrow")
    func boundsOnlyMerging() {
        let cleanup = TimelineFlushSummary(committedHistoryRevision: 1, includesUnreportedHistory: true,
                                           onlyUnadmittedChanges: true)
        #expect(cleanup.merging(cleanup).canRefreshBoundsOnly)
        for other in [TimelineFlushSummary(setCount: 1, redactedUpsertCount: 1),
                      .init(pushFrontCount: 1), .init(requiresPresentationRefresh: true), repair(2)] {
            #expect(!cleanup.merging(other).canRefreshBoundsOnly)
            #expect(!other.merging(cleanup).canRefreshBoundsOnly)
            #expect(!cleanup.merging(other).allowsRemoteRedactionAnimation)
        }
    }
}
