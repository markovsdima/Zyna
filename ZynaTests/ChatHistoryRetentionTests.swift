//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import GRDB
import Testing
import UIKit
@testable import Zyna

@Suite("Chat history retention", .serialized)
@MainActor
struct ChatHistoryRetentionTests {
    private let policy = ChatHistoryRetentionPolicy()
    private let roomID = TimelineWriteFixture.roomID

    @Test("An arrival merged with recovered history follows the live edge but preserves a scrolled viewport",
          arguments: [false, true])
    func arrivalDuringRecovery(scrolled: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<50).map(TimelineWriteFixture.message))
        let history = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: history, mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { chat.finishNavigationSession(); window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        model.prepareInitialHistoryWindow()
        let list = chat.node.list
        try await ChatBackgroundPresentationTests.wait { list.layout.geometry.ids.count >= 50 }
        await withCheckedContinuation { continuation in
            list.onDidFinishProcessingUpdates { continuation.resume() }
        }
        let before = scrolled ? CGFloat(300) : -list.view.adjustedContentInset.top
        list.contentOffset.y = before
        list.view.layoutIfNeeded()
        let anchor = try #require(list.indexPathsForVisibleItems().first)
        let anchorID = try #require(model.rows[anchor.row].message?.eventId)
        let anchorY = list.rectForItem(at: anchor).minY - list.contentOffset.y
        try await database.write { db in
            try TimelineWriteFixture.message(50).insert(db)
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Recovered history' WHERE id = 'row-0'")
        }
        model.refreshPresentationForTesting(.init(pushBackCount: 1, incomingMessageCount: 1,
                                                 includesUnreportedHistory: true))
        try await ChatBackgroundPresentationTests.wait { model.isTimelineRefreshIdleForTesting && model.messages.count == 51 }
        await withCheckedContinuation { continuation in
            list.onDidFinishProcessingUpdates { continuation.resume() }
        }
        list.view.layoutIfNeeded()
        if scrolled {
            let after = try #require(model.indexOfMessage(eventId: anchorID))
            #expect(abs(list.rectForItem(at: IndexPath(row: after, section: 0)).minY - list.contentOffset.y - anchorY) < 1)
        } else {
            #expect(abs(list.contentOffset.y + list.view.adjustedContentInset.top) < 1)
        }
    }

    @Test("A covered chat keeps its anchor when a prepared newer page reaches live")
    func newerPageReachesLive() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<240).map(TimelineWriteFixture.message))
        let history = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: history, mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { chat.finishNavigationSession(); window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        // Keep preparing real Texture updates, but prevent automatic prefetch
        // from consuming the final page before the controlled request below.
        chat.setNavigationContentVisible(false, prepareWhileHidden: true)
        let list = chat.node.list
        await withCheckedContinuation { continuation in
            model.prepareHistoryReplacement(.oldest) { apply in
                apply()
                continuation.resume()
            }
        }
        try await ChatBackgroundPresentationTests.wait { list.layout.geometry.ids.count >= 200 && model.messages.first?.eventId == "$event-199" }
        await withCheckedContinuation { continuation in list.onDidFinishProcessingUpdates { continuation.resume() } }
        #expect(!model.isAtLiveEdge)
        list.contentOffset.y = -list.view.adjustedContentInset.top
        list.view.layoutIfNeeded()
        let index = try #require(model.indexOfMessage(eventId: "$event-199"))
        let before = list.rectForItem(at: IndexPath(row: index, section: 0)).minY - list.contentOffset.y
        // Deliver an already prepared page directly to the window: covered
        // routes deliberately refuse to start new pagination requests.
        let request = try #require(history.pageRequest(.newer))
        let page = try await Task.detached { try request.fetch() }.value
        #expect(history.applyPage(page))
        try await model.waitForPresentation()
        await withCheckedContinuation { continuation in list.onDidFinishProcessingUpdates { continuation.resume() } }
        #expect(model.isAtLiveEdge)
        let afterIndex = try #require(model.indexOfMessage(eventId: "$event-199"))
        let after = list.rectForItem(at: IndexPath(row: afterIndex, section: 0)).minY - list.contentOffset.y
        #expect(abs(before - after) < 1)
        #expect(list.contentOffset.y > -list.view.adjustedContentInset.top + 100)
    }

    @Test("A delayed live jump respects manual scrolling and an already reached endpoint", arguments: [0, 1, 2])
    func liveButtonDuringRecovery(scenario: Int) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<600).map(TimelineWriteFixture.message))
        let history = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: history, mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; model.cleanup() }
        chat.view.layoutIfNeeded()
        model.prepareInitialHistoryWindow()
        let list = chat.node.list
        try await ChatBackgroundPresentationTests.wait { list.layout.geometry.ids.count >= 200 }
        let index = try #require(model.indexOfMessage(eventId: "$event-480"))
        list.scrollToItem(at: IndexPath(row: index, section: 0), at: .centeredVertically, animated: false)
        list.view.layoutIfNeeded()
        #expect(list.contentOffset.y > list.bounds.height * 2)

        let entered = Atomic(false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        model.onRenderPreparedForTesting = {
            if entered.tryToSetFlag() { #expect(gate.wait(timeout: .now() + 5) == .success) }
        }
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await ChatBackgroundPresentationTests.wait { entered.wrappedValue }
        let button = try #require(chat.node.scrollButtonTap as? UIButton)
        let generation = history.generation
        let previousOffset = list.contentOffset.y
        button.sendActions(for: .touchUpInside)
        if scenario == 1 {
            chat.scrollViewWillBeginDragging(list.view)
        } else if scenario == 2 {
            list.contentOffset = CGPoint(x: 0, y: -list.view.adjustedContentInset.top)
        }
        gate.signal()
        let targetOffset = scenario == 1 ? previousOffset : -list.view.adjustedContentInset.top
        try await ChatBackgroundPresentationTests.wait {
            model.isTimelineRefreshIdleForTesting
                && abs(list.contentOffset.y - targetOffset) < 1
        }
        try await model.drainPresentationWorkerForTesting()
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(list.contentOffset.y - targetOffset) < 1)
        #expect(model.messages.first?.id == "row-599")
        if scenario != 0 { #expect(history.generation == generation) }
    }

    @Test("The title debug gesture cannot start over expanded voice controls")
    func debugTitleGesture() throws {
        let database = try TimelineWriteFixture.database()
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database,
            window: MessageWindow(roomId: roomID, dbQueue: database), mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        defer { model.cleanup() }
        chat.loadViewIfNeeded()
        let bar = try #require(chat.node.subnodes?.compactMap { $0 as? GlassNavBar }.first)
        let gesture = try #require(bar.titleNode.view.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        #expect(gesture.delegate === chat)
        #expect(chat.gestureRecognizerShouldBegin(gesture))
        bar.titleNode.voiceExpanded = true
        #expect(!chat.gestureRecognizerShouldBegin(gesture))
        bar.titleNode.voiceExpanded = false
        #expect(chat.gestureRecognizerShouldBegin(gesture))
    }

    @Test("A late Texture fetch waits for retention and is released on chat cleanup", arguments: [false, true])
    func queuedFetch(close: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<1_000).map(TimelineWriteFixture.message))
        let history = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: history, mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; model.cleanup() }
        chat.view.layoutIfNeeded()
        chat.lockInteraction("contextMenu")
        model.prepareInitialHistoryWindow()
        try await ChatBackgroundPresentationTests.wait { chat.node.list.layout.geometry.ids.count >= 200 }
        let request = try #require(history.pageRequest(.older, count: 450))
        // Fixture setup is atomic on main so automatic initial prefetch cannot
        // invalidate it; the retention/page race below still runs on the worker.
        #expect(history.applyPage(try request.fetch()))
        try await ChatBackgroundPresentationTests.wait { chat.node.list.layout.geometry.ids.count >= 650 }
        let list = chat.node.list
        let index = try #require(model.indexOfMessage(eventId: "$event-500"))
        list.scrollToItem(at: IndexPath(row: index, section: 0), at: .centeredVertically, animated: false)
        list.view.layoutIfNeeded()
        let entered = Atomic(false), preparations = Atomic(0)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        model.onRenderPreparedForTesting = {
            preparations.modify { $0 += 1 }
            if entered.tryToSetFlag() { #expect(gate.wait(timeout: .now() + 5) == .success) }
        }
        chat.unlockInteraction("contextMenu")
        try await ChatBackgroundPresentationTests.wait { entered.wrappedValue }
        #expect(list.shouldFetch?() == true)
        let context = ASBatchContext()
        context.beginBatchFetching()
        list.beginFetch?(context)
        // Allow the already dispatched Texture callback to reach main.
        try await Task.sleep(for: .milliseconds(20))
        #expect(context.isFetching())
        if close { chat.finishNavigationSession() }
        gate.signal()
        try await ChatBackgroundPresentationTests.wait { !context.isFetching() }
        if !close {
            #expect(history.retainedMessageCount == 450)
            // One retention and one page; no stale page prepared/retried.
            #expect(preparations.wrappedValue == 2)
        } else {
            #expect(history.retainedMessageCount >= 650)
        }
    }

    @Test("Default chat trims in both directions, preserves playback and counts arrivals outside its window")
    func controllerPaging() async throws {
        var records = (0..<1_000).map(TimelineWriteFixture.message)
        records[999].contentType = "voice"
        records[999].contentMediaJSON = "{\"url\":\"mxc://example.org/voice\"}"
        records[999].contentVoiceDuration = 60
        let database = try TimelineWriteFixture.database(legacyMessages: records)
        let stored = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: stored, mode: .normal)
        let player = AudioPlayerService()
        let audioURL = try ProfileVoiceAudioFixture.make()
        defer { player.stop(); try? FileManager.default.removeItem(at: audioURL) }
        let chat = ChatViewController(viewModel: model, audioPlayer: player)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; model.cleanup() }
        chat.view.layoutIfNeeded()
        model.prepareInitialHistoryWindow()
        try await ChatBackgroundPresentationTests.wait { chat.node.list.layout.geometry.ids.count >= 200 }
        let voiceIndex = try #require(model.indexOfMessage(eventId: "$event-999"))
        weak var voiceCell = chat.node.list.nodeForItem(at: IndexPath(row: voiceIndex, section: 0)) as? VoiceMessageCellNode
        try #require(voiceCell != nil)
        player.playLocal(url: audioURL, sourceKey: "mxc://example.org/voice", nowPlaying: .voice(.init(
            sourceURL: "mxc://example.org/voice", title: "Alice", subtitle: nil,
            duration: 60, waveform: [], roomId: roomID, eventId: "$event-999")))
        for direction in [MessageWindow.PageDirection.older, .newer] {
            var steps = 0
            while direction == .older ? stored.hasOlderInDB : stored.hasNewerInDB {
                steps += 1
                try #require(steps < 40)
                let previous = direction == .older ? model.messages.last?.id : model.messages.first?.id
                let list = chat.node.list
                list.contentOffset.y = direction == .older
                    ? max(-list.view.adjustedContentInset.top,
                        list.view.contentSize.height - list.bounds.height + list.view.adjustedContentInset.bottom - 50)
                    : -list.view.adjustedContentInset.top + 50
                list.view.layoutIfNeeded()
                chat.scrollViewDidScroll(list.view)
                try await ChatBackgroundPresentationTests.wait {
                    let current = direction == .older ? model.messages.last?.id : model.messages.first?.id
                    return current != previous && list.layout.geometry.ids.count == model.rows.count
                }
            }
            try await ChatBackgroundPresentationTests.wait { stored.retainedMessageCount <= 600 }
            #expect(stored.retainedMessageCount <= 600)
            if direction == .older {
                try await ChatBackgroundPresentationTests.wait { voiceCell == nil }
                #expect(player.state.isPlaying && player.nowPlaying?.eventId == "$event-999")
                let retained = model.messages.map(\.id)
                let roomID = roomID
                let summary = try await Task.detached {
                    var summary = TimelineFlushSummary()
                    try TimelineDiffBatcher.writeMappedEvents(
                        [TimelineWriteFixture.event(TimelineWriteFixture.message(1_000)) + [.liveArrival]],
                        roomId: roomID, database: database, currentUserId: "", summary: .init(pushBackCount: 1),
                        historyRevision: TimelineHistoryRevision()) { summary = $0 }
                    return summary
                }.value
                model.refreshPresentationForTesting(summary)
                try await ChatBackgroundPresentationTests.wait { model.isTimelineRefreshIdleForTesting }
                #expect(model.messages.map(\.id) == retained)
                #expect(chat.node.scrollButtonTap?.accessibilityLabel == "Scroll to latest messages, 1 unread")
            }
        }
        #expect(model.messages.first?.eventId == "$event-1000")
        #expect(stored.isAtLiveEdge)
        #expect(stored.hasOlderInDB)
        let restoredVoiceIndex = try #require(model.indexOfMessage(eventId: "$event-999"))
        #expect(chat.node.list.nodeForItem(at: IndexPath(row: restoredVoiceIndex, section: 0)) is VoiceMessageCellNode)
        #expect(player.state.isPlaying && player.nowPlaying?.eventId == "$event-999")
        // A reply/link to an evicted event uses the ordinary navigation path.
        let prepared = try await chat.preparePollNavigation(eventId: "$event-42", targetKind: .message)
        #expect(prepared.open())
        try await ChatBackgroundPresentationTests.wait {
            guard let index = model.indexOfMessage(eventId: "$event-42") else { return false }
            let list = chat.node.list
            return CGRect(origin: list.contentOffset, size: list.bounds.size)
                .intersects(list.rectForItem(at: IndexPath(row: index, section: 0)))
        }
    }

    @Test("An interaction lock defers retention and unlocking resumes it without moving the viewport")
    func interactionLock() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<1_000).map(TimelineWriteFixture.message))
        let history = MessageWindow(roomId: roomID, dbQueue: database)
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database, window: history, mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; model.cleanup() }
        chat.view.layoutIfNeeded()
        chat.lockInteraction("contextMenu")
        model.prepareInitialHistoryWindow()
        try await ChatBackgroundPresentationTests.wait { chat.node.list.layout.geometry.ids.count >= 200 }
        let request = try #require(history.pageRequest(.older, count: 450))
        // Fixture setup is atomic on main so automatic initial prefetch cannot
        // invalidate it; the retention/page race below still runs on the worker.
        #expect(history.applyPage(try request.fetch()))
        try await ChatBackgroundPresentationTests.wait { chat.node.list.layout.geometry.ids.count >= 650 }
        // Texture may have prefetched one more page; the lock must keep
        // the expanded history intact until the interaction finishes.
        #expect(history.retainedMessageCount >= 650)
        let list = chat.node.list
        let index = try #require(model.indexOfMessage(eventId: "$event-500"))
        list.scrollToItem(at: IndexPath(row: index, section: 0), at: .centeredVertically, animated: false)
        list.view.layoutIfNeeded()
        let before = list.rectForItem(at: IndexPath(row: index, section: 0)).minY - list.contentOffset.y
        chat.unlockInteraction("contextMenu")
        try await ChatBackgroundPresentationTests.wait {
            history.retainedMessageCount <= 600 && list.layout.geometry.ids.count == model.rows.count
        }
        let retainedIndex = try #require(model.indexOfMessage(eventId: "$event-500"))
        let after = list.rectForItem(at: IndexPath(row: retainedIndex, section: 0)).minY - list.contentOffset.y
        #expect(abs(after - before) < 1)
    }

    @Test("The window walks the entire local history in both directions without growing", arguments: [false, true])
    func roundTrip(equalTimestamps: Bool) async throws {
        let count = 2_400
        let records = (0..<count).map { index in
            var record = TimelineWriteFixture.message(index)
            if equalTimestamps { record.timestamp = 42 }
            return record
        }
        let database = try TimelineWriteFixture.database(legacyMessages: records)
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        window.loadInitial()
        let generation = window.generation
        var seen = Set(window.currentStoredMessages().map(\.id))
        var trims = 0
        for direction in [MessageWindow.PageDirection.older, .newer] {
            var steps = 0
            while direction == .older ? window.hasOlderInDB : window.hasNewerInDB {
                steps += 1
                try #require(steps < 100)
                let request = try #require(window.pageRequest(direction))
                let page = try await Task.detached { try request.fetch() }.value
                #expect(window.applyPage(page))
                seen.formUnion(window.currentStoredMessages().map(\.id))
                #expect(window.retainedMessageCount <= policy.maximumCount + MessageWindow.pageSize)
                if window.retainedMessageCount > policy.maximumCount {
                    let records = window.currentStoredMessages()
                    let anchor = try #require(direction == .older ? records.last : records.first)
                    let page = try await retention(window, keys: anchor.timelineIdentityKeys)
                    #expect(window.applyRetention(page))
                    #expect(window.retainedMessageCount == policy.retainedCount)
                    #expect(window.currentStoredMessages().contains { $0.id == anchor.id })
                    trims += 1
                }
            }
        }
        #expect(seen.count == count)
        #expect(trims > 10)
        #expect(window.generation == generation)
        #expect(window.isAtLiveEdge)
        #expect(window.hasOlderInDB)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == count)
    }

    @Test("Retention preserves progress through unresolved pages at an unchanged raw edge",
          arguments: [MessageWindow.PageDirection.older, .newer])
    func excludedPageCursor(direction: MessageWindow.PageDirection) async throws {
        var records = (0..<1_000).map(TimelineWriteFixture.message)
        for index in direction == .older ? 300..<350 : 650..<700 {
            records[index].contentType = "unableToDecrypt"
        }
        let database = try TimelineWriteFixture.database(legacyMessages: records)
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        if direction == .older { window.loadInitial() } else { window.jumpToOldest() }
        for count in [450, 50] {
            let request = try #require(window.pageRequest(direction, count: count))
            #expect(window.applyPage(try await Task.detached { try request.fetch() }.value))
        }
        #expect(window.retainedMessageCount == 650)
        let anchor = try #require(direction == .older
            ? window.currentStoredMessages().last : window.currentStoredMessages().first)
        #expect(window.applyRetention(try await retention(window, keys: anchor.timelineIdentityKeys)))
        let request = try #require(window.pageRequest(direction, count: 1))
        #expect(window.applyPage(try await Task.detached { try request.fetch() }.value))
        let expectedID = direction == .older ? "row-299" : "row-700"
        #expect(window.currentStoredMessages().contains { $0.id == expectedID })
    }

    @Test("Retention invalidates pending pages and refreshes, and is itself invalidated by a jump")
    func staleReads() async throws {
        let (_, window) = try await expandedWindow()
        let pageRequest = try #require(window.pageRequest(.older))
        let refreshRequest = window.refreshRequest()
        let pendingPage = try await Task.detached { try pageRequest.fetch() }.value
        let pendingRefresh = try await Task.detached { try refreshRequest.fetch() }.value
        let retained = try await retention(window, keys: TimelineWriteFixture.message(400).timelineIdentityKeys)
        #expect(window.applyRetention(retained))
        #expect(!window.applyPage(pendingPage))
        #expect(!window.applyRefresh(pendingRefresh, summary: .init()))
        #expect(!window.applyRetention(retained))

        let (_, other) = try await expandedWindow()
        let abandoned = try await retention(other, keys: TimelineWriteFixture.message(400).timelineIdentityKeys)
        other.jumpToLive()
        #expect(!other.applyRetention(abandoned))
    }

    @Test("Live arrivals do not refill an evicted edge; edits and jumps still work")
    func refreshAndNavigation() async throws {
        let (database, window) = try await expandedWindow()
        let retained = try await retention(window, keys: TimelineWriteFixture.message(400).timelineIdentityKeys)
        #expect(window.applyRetention(retained))
        #expect(!window.isAtLiveEdge)
        #expect(window.position(of: "$event-999") == .newerThanCurrentWindow)
        let retainedIDs = window.currentStoredMessages().map(\.id)
        try await database.write { db in
            try TimelineWriteFixture.message(1_000).insert(db)
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Edited' WHERE id = 'row-400'")
            try db.execute(sql: "UPDATE storedMessage SET contentBody = 'Edited while evicted' WHERE id = 'row-999'")
            try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted' WHERE id = 'row-998'")
        }
        window.refresh()
        #expect(window.currentStoredMessages().map(\.id) == retainedIDs)
        #expect(window.currentStoredMessages().first { $0.id == "row-400" }?.contentBody == "Edited")
        window.jumpTo(eventId: "$event-999")
        #expect(window.currentStoredMessages().first { $0.eventId == "$event-999" }?.contentBody == "Edited while evicted")
        #expect(window.currentStoredMessages().first { $0.eventId == "$event-998" }?.contentType == "redacted")
        window.jumpToLive()
        #expect(window.currentStoredMessages().first?.eventId == "$event-1000")
        #expect(window.isAtLiveEdge)
    }

    @Test("Retention uses separate watermarks and keeps a protected viewport")
    func hysteresis() async throws {
        let (_, window) = try await expandedWindow()
        #expect(window.retainedMessageCount == 650)
        #expect(policy.retainedRange(count: 600, protected: 0..<20) == nil)
        #expect(policy.retainedRange(count: 650, protected: 0..<20) == 0..<400)
        #expect(policy.retainedRange(count: 650, protected: 630..<650) == 250..<650)
        #expect(policy.retainedRange(count: 650, protected: 300..<320) == 110..<510)
        #expect(policy.retainedRange(count: 650, protected: 100..<510) == nil)
    }

    @Test("Retention does not cut a media group at a window boundary")
    func completeBoundaryGroups() async throws {
        var records = (0..<1_000).map(TimelineWriteFixture.message)
        // Protect row 400: the nominal retained range is rows 350...749.
        // A group crossing the newer boundary must remain whole.
        for index in 745...755 {
            records[index].zynaAttributesJSON = StoredMessage.encodeZynaAttributes(.init(mediaGroup: .init(
                id: "boundary-group", index: index - 745, total: 11,
                captionMode: .replicated, captionPlacement: .bottom)))
        }
        let database = try TimelineWriteFixture.database(legacyMessages: records)
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        window.loadInitial()
        let request = try #require(window.pageRequest(.older, count: 450))
        #expect(window.applyPage(try await Task.detached { try request.fetch() }.value))
        let retained = try await retention(window, keys: records[400].timelineIdentityKeys)
        #expect(window.applyRetention(retained))
        let ids = Set(window.currentStoredMessages().map(\.id))
        #expect((745...755).allSatisfy { ids.contains("row-\($0)") })
        #expect(window.retainedMessageCount == 406)
    }

    private func expandedWindow() async throws -> (AccountDatabase, MessageWindow) {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<1_000).map(TimelineWriteFixture.message))
        let window = MessageWindow(roomId: roomID, dbQueue: database)
        window.loadInitial()
        let request = try #require(window.pageRequest(.older, count: 450))
        #expect(window.applyPage(try await Task.detached { try request.fetch() }.value))
        return (database, window)
    }

    private func retention(_ window: MessageWindow, keys: Set<String>) async throws -> MessageWindow.RetentionPage {
        let request = try #require(window.retentionRequest(protecting: keys, policy: policy))
        return try #require(try await Task.detached { try request.fetch() }.value)
    }
}
