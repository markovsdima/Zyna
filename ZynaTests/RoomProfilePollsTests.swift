// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import GRDB
import Testing
import UIKit
@testable import Zyna

@MainActor
final class ProfilePollHistory: RoomPollHistorySource {
    var onChange: ((RoomPollHistoryState) -> Void)?
    private(set) var starts = 0
    private(set) var retries = 0
    private(set) var loads = 0
    var fail = false
    var holdStart = false
    var startGate: CheckedContinuation<Void, Never>?
    var holdPage = false
    var pageGate: CheckedContinuation<Bool, Never>?
    var reachesStart = true
    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startGate = $0 } }
    }
    func loadMore() async throws -> Bool {
        loads += 1
        if fail { throw URLError(.notConnectedToInternet) }
        if holdPage { return await withCheckedContinuation { pageGate = $0 } }
        return reachesStart
    }
    func synchronize() async throws {}
    func retryDecryption() { retries += 1 }
    func stop() {}
}

@Suite("Texture profile polls", .serialized)
@MainActor
struct RoomProfilePollsTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView, id: String) -> T? {
        if root.accessibilityIdentifier == id { return root as? T }
        return root.subviews.lazy.compactMap { find(type, in: $0, id: id) }.first
    }

    private func seed(_ count: Int) async throws -> (AccountDatabase, RoomPollCatalog) {
        try await Task.detached {
            let database = try RoomPollFixture.database()
            let catalog = RoomPollCatalog(roomId: RoomPollFixture.roomID, database: database)
            try catalog.ingest((0..<count).map {
                (RoomPollFixture.poll("$poll-\($0)", time: Double($0)).record!, true, .unavailable)
            })
            return (database, catalog)
        }.value
    }

    @Test("The profile preloads a bounded poll page without SDK discovery and displays it during refresh")
    func cachedFirstPage() async throws {
        let (_, catalog) = try await seed(55)
        let source = ProfilePollHistory()
        source.holdStart = true
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: nil,
            actions: .none, pollsModel: model, initialSection: .media)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer {
            model.stop()
            source.startGate?.resume(); source.startGate = nil
            window.isHidden = true; window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        try await wait { model.hasLoadedCache }
        #expect(model.items.count == 30 && model.state == .idle && source.starts == 0)
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.polls") == nil)
        controller.selectSection(.polls, animated: false)
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.polls"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { source.startGate != nil && list.numberOfSections > 0
            && list.numberOfItems(inSection: 0) == 30 && !page.isAdjusting }
        #expect(model.state == .loading && model.isRefreshing && source.loads == 0)
        let first = try #require(page.node.nodeForItem(at: IndexPath(item: 0, section: 0)))
        #expect(first.accessibilityLabel?.contains("$poll-54") == true)
        #expect(!RoomProfilePollSnapshot(model: model).rows().contains { $0.id == "polls.status" })
        source.startGate?.resume(); source.startGate = nil
        try await wait { model.state == .more }
        model.loadMore()
        #expect(RoomProfilePollSnapshot(model: model).rows().last?.title == String(localized: "Loading"))
        try await wait { model.items.count == 55 && model.state == .exhausted }
        #expect(source.starts == 1)
    }

    @Test("An empty cache shows loading only after its read, until discovery confirms the empty state")
    func emptyCache() async throws {
        let (_, catalog) = try await seed(0)
        let source = ProfilePollHistory()
        source.holdStart = true
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        defer {
            model.stop()
            source.startGate?.resume(); source.startGate = nil
        }
        #expect(RoomProfilePollSnapshot(model: model).rows().isEmpty)
        model.activate()
        #expect(RoomProfilePollSnapshot(model: model).rows().isEmpty)
        try await wait { model.hasLoadedCache && source.startGate != nil }
        #expect(RoomProfilePollSnapshot(model: model).rows().last?.title == String(localized: "Loading"))
        source.startGate?.resume(); source.startGate = nil
        try await wait { model.state == .exhausted }
        #expect(RoomProfilePollSnapshot(model: model).rows().last?.title == String(localized: "No polls yet."))
    }

    @Test("Polls start lazily, keep their anchor after eviction and refresh hidden catalog changes")
    func pagingAndEviction() async throws {
        let (database, catalog) = try await seed(55)
        let source = ProfilePollHistory()
        let model = RoomPollsViewModel(catalog: catalog, source: source, pageSize: 100, settleQuiet: 0)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: nil,
            actions: .none, pollsModel: model, initialSection: .voice)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        // Peeking at the adjacent page must not start SDK history.
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 2.3
        #expect(source.starts == 0)
        pager.contentOffset.x = pager.bounds.width * 2
        controller.scrollViewDidEndDragging(pager, willDecelerate: false)
        controller.selectSection(.polls, animated: false)
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.polls"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { model.state == .exhausted && list.numberOfSections > 0
            && list.numberOfItems(inSection: 0) == 55 && !page.isAdjusting }
        #expect(source.starts == 1)
        list.contentOffset.y = 1_200
        let anchor = try #require(page.captureAnchor())
        controller.selectSection(.files, animated: false)
        controller.didReceiveMemoryWarning()
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.polls") == nil)
        let oldName = model.items.first?.senderName
        try await database.write { try $0.execute(sql: "UPDATE roomPoll SET senderName = 'Updated sender'") }
        try await Task.detached {
            try catalog.ingest([(RoomPollFixture.poll("$new", time: 999).record!, true, .unavailable)])
        }.value
        #expect(model.items.first?.senderName == oldName)
        controller.selectSection(.polls, animated: false)
        let restoredList = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.polls"))
        let restoredPage = try #require(restoredList.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { model.items.count == 56 && restoredList.numberOfSections > 0
            && restoredList.numberOfItems(inSection: 0) == 56 && !restoredPage.isAdjusting }
        let restored = try #require(restoredPage.captureAnchor())
        #expect(restored.id == anchor.id && abs(restored.offset - anchor.offset) < 1)
        #expect(source.starts == 1 && model.items.contains { $0.senderName == "Updated sender" })
    }

    @Test("Returning to a short poll page replays near-end demand received before section activation")
    func restoredNearEnd() async throws {
        let (_, catalog) = try await seed(3)
        let source = ProfilePollHistory()
        source.reachesStart = false
        let model = RoomPollsViewModel(catalog: catalog, source: source, pageSize: 1, fillBudget: 0, settleQuiet: 0)
        let binding = RoomProfilePollsSection(model: model)
        let page = RoomProfileListPage()
        binding.attach(to: page)
        binding.isActive = true
        defer { binding.stop() }
        try await wait { model.state == .more && model.items.count == 1 }
        binding.isActive = false
        // This is the viewWillAppear order: the page reports its geometry
        // before the section receives its own activation.
        page.onNearEnd?(true)
        binding.isActive = true
        try await wait { model.items.count == 2 && model.state == .more }
        #expect(source.starts == 1)
    }

    @Test("An uncommitted swipe preserves sparse discovery until the next SDK page", arguments: [false, true])
    func pagingDiscovery(resize: Bool) async throws {
        let (_, catalog) = try await seed(0)
        let source = ProfilePollHistory()
        source.holdPage = true
        let model = RoomPollsViewModel(catalog: catalog, source: source, fillBudget: 30, settleQuiet: 0)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: nil,
            actions: .none, pollsModel: model, initialSection: .polls)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer {
            model.stop()
            source.pageGate?.resume(returning: true); source.pageGate = nil
            window.isHidden = true; window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        try await wait { source.pageGate != nil }
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 2.6
        let firstPage = source.pageGate; source.pageGate = nil
        firstPage?.resume(returning: false)
        try await wait { source.loads == 2 && source.pageGate != nil }
        #expect(model.state == .loading)
        if resize {
            controller.view.frame.size.width = 320
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        } else {
            pager.contentOffset.x = pager.bounds.width * 3
            controller.scrollViewDidEndDragging(pager, willDecelerate: false)
        }
        source.holdPage = false
        source.pageGate?.resume(returning: true); source.pageGate = nil
        try await wait { model.state == .exhausted }
        #expect(source.starts == 1 && source.loads == 3)
    }

    @Test("A prepared poll waits for paging, opens after cancellation and is discarded when leaving",
          arguments: [0, 1, 2])
    func pagingNavigation(outcome: Int) async throws {
        let (_, catalog) = try await seed(1)
        let model = RoomPollsViewModel(catalog: catalog, source: ProfilePollHistory(), settleQuiet: 0)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: nil,
            actions: .none, pollsModel: model, initialSection: .polls)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        var gate: CheckedContinuation<Void, Never>?
        var prepared = false, opened = 0
        defer {
            model.stop(); gate?.resume()
            window.isHidden = true; window.rootViewController = nil
        }
        controller.onShowInChat = { _, _ in
            await withCheckedContinuation { gate = $0 }
            prepared = true
            return PreparedPollNavigation { opened += 1; return true }
        }
        controller.view.layoutIfNeeded()
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.polls"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { model.state == .exhausted && !page.isAdjusting }
        page.onPollAction?(.open("$poll-0"))
        try await wait { gate != nil }
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 2.6
        #expect(model.openingEventId == "$poll-0")
        gate?.resume(); gate = nil
        try await wait { prepared }
        #expect(opened == 0 && model.openingEventId == "$poll-0")
        if outcome == 2 {
            controller.view.frame.size.width = 320
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        } else {
            pager.contentOffset.x = pager.bounds.width * (outcome == 0 ? 3 : 2)
            controller.scrollViewDidEndDragging(pager, willDecelerate: false)
        }
        try await wait { model.openingEventId == nil }
        #expect(opened == (outcome == 1 ? 0 : 1))
    }

    @Test("Poll rows expose loading, retry and cancellation; leaving rejects a late navigation result")
    func navigation() async throws {
        let (_, catalog) = try await seed(1)
        let model = RoomPollsViewModel(catalog: catalog, source: ProfilePollHistory(), settleQuiet: 0)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: nil,
            actions: .none, pollsModel: model, initialSection: .polls)
        var gate: CheckedContinuation<PreparedPollNavigation, Never>?
        defer { gate?.resume(returning: PreparedPollNavigation { false }) }
        var fail = true
        var opened = 0
        controller.onShowInChat = { id, target in
            #expect(id == "$poll-0" && target.accepts("poll") && !target.accepts("text"))
            if fail { throw PollNavigationError.unavailable }
            return await withCheckedContinuation { gate = $0 }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 690))
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.polls"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        func cell() -> ListContextMenuCellNode? {
            page.node.nodeForItem(at: IndexPath(item: 0, section: 0)) as? ListContextMenuCellNode
        }
        try await wait { model.state == .exhausted && cell() != nil && !page.isAdjusting }
        cell()?.onQuickTap?()
        try await wait { cell()?.accessibilityLabel?.contains(String(localized:
            "Couldn't open poll. Tap to try again.", table: "RoomProfile")) == true }
        fail = false
        cell()?.onQuickTap?()
        try await wait { gate != nil && cell()?.accessibilityLabel?.contains(String(localized:
            "Opening poll… Tap to cancel.", table: "RoomProfile")) == true }
        // A second tap on the loading row cancels that specific request.
        cell()?.onQuickTap?()
        try await wait { model.openingEventId == nil && !page.isAdjusting }
        gate?.resume(returning: PreparedPollNavigation { opened += 1; return true }); gate = nil
        try await wait { cell()?.accessibilityHint == String(localized: "Open poll in chat") }
        cell()?.onQuickTap?()
        try await wait { gate != nil }
        controller.selectSection(.files, animated: false)
        gate?.resume(returning: PreparedPollNavigation { opened += 1; return true }); gate = nil
        controller.selectSection(.polls, animated: false)
        try await wait { model.openingEventId == nil && cell()?.accessibilityHint == String(localized: "Open poll in chat") }
        #expect(opened == 0)
        cell()?.onQuickTap?()
        try await wait { gate != nil }
        gate?.resume(returning: PreparedPollNavigation { opened += 1; return true }); gate = nil
        try await wait { opened == 1 && model.openingEventId == nil }
    }

    @Test("Empty, missing-key and failed history states retain their own actions")
    func footerStates() async throws {
        let (_, catalog) = try await seed(0)
        let source = ProfilePollHistory()
        source.fail = true
        let model = RoomPollsViewModel(catalog: catalog, source: source, settleQuiet: 0)
        let binding = RoomProfilePollsSection(model: model)
        let page = RoomProfileListPage()
        page.node.frame = CGRect(x: 0, y: 0, width: 320, height: 690)
        page.install()
        binding.attach(to: page)
        binding.isActive = true
        defer { binding.stop() }
        try await wait { if case .failed = model.state { return true }; return false }
        source.onChange?(.init(pendingCount: 3))
        let snapshot = RoomProfilePollSnapshot(model: model)
        let rows = await Task.detached { snapshot.rows() }.value
        #expect(!rows.contains { $0.title == String(localized: "No polls yet.") })
        #expect(rows.contains { $0.pollAction == .retryDecryption } && rows.contains { $0.pollAction == .loadMore })
        try await wait { page.node.numberOfSections > 0 && page.node.numberOfItems(inSection: 0) == 2 && !page.isAdjusting }
        page.collectionNode(page.node, didSelectItemAt: IndexPath(item: 0, section: 0))
        #expect(source.retries == 1)
        source.fail = false
        source.onChange?(.init(pendingCount: 0))
        page.onPollAction?(.loadMore)
        try await wait { model.state == .exhausted }
        #expect(RoomProfilePollSnapshot(model: model).rows().last?.title == String(localized: "No polls yet."))
    }

    @Test("Undisclosed results stay hidden until completion and edited poll text refreshes in place")
    func pollResults() async throws {
        let (database, catalog) = try await seed(1)
        try await database.write { db in
            var stored = try #require(try StoredRoomPoll.fetchOne(db))
            var snapshot = try #require(stored.snapshot)
            snapshot.definition.kind = .undisclosed
            snapshot.totalVoters = 321
            stored.snapshotJSON = try PollCoding.encode(snapshot)
            try stored.update(db)
        }
        let model = RoomPollsViewModel(catalog: catalog, source: ProfilePollHistory(), settleQuiet: 0)
        model.activate(); defer { model.stop() }
        try await wait { model.state == .exhausted && model.items.count == 1 }
        let hidden = try #require(RoomProfilePollSnapshot(model: model).rows().first?.poll)
        #expect(hidden.summary.contains(String(localized: "Results after the poll ends")))
        #expect(!hidden.summary.contains("321"))
        try await database.write { db in
            var stored = try #require(try StoredRoomPoll.fetchOne(db))
            var snapshot = try #require(stored.snapshot)
            snapshot.definition.question = "Edited poll question"
            snapshot.endTimestamp = 200
            stored.snapshotJSON = try PollCoding.encode(snapshot)
            try stored.update(db)
        }
        try await wait { model.items.first?.snapshot.hasEnded == true }
        let ended = try #require(RoomProfilePollSnapshot(model: model).rows().first?.poll)
        #expect(ended.question == "Edited poll question" && ended.eventID == hidden.eventID)
        #expect(ended.summary.contains("321") && ended.summary.contains(String(localized: "Poll ended")))
        try await database.write { try $0.execute(sql: "UPDATE roomPoll SET isRedacted = 1") }
        try await wait { model.items.isEmpty }
        #expect(RoomProfilePollSnapshot(model: model).rows().first?.title == String(localized: "No polls yet."))
    }
}
