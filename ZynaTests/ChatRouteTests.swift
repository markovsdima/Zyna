// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import GRDB
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private final class RouteResident: UIViewController, NavigationResidentScreen {
    var resident = false
    var visible = false
    var loads = 0
    func materializeContent() { if !resident { loads += 1 }; resident = true }
    func releaseContent() { resident = false }
    func setContentVisible(_ visible: Bool) { self.visible = visible }
}

private final class RouteWeakChat {
    weak var value: ChatViewController?
    init(_ value: ChatViewController) { self.value = value }
}

private final class RoutePan: UIPanGestureRecognizer {
    var simulatedState: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { simulatedState }
        set { simulatedState = newValue }
    }
}

private final class RouteListenerHandle: TaskHandle, @unchecked Sendable {
    let cancellations = Atomic(0)
    override func cancel() { cancellations.modify { $0 += 1 } }
}

private final class RouteTimeline: Timeline, @unchecked Sendable {
    let request = ProfileTestRequest<TaskHandle>()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func addListener(listener: any TimelineListener) async -> TaskHandle { try! await request.wait() }
}

private final class RouteRoom: Room, @unchecked Sendable {
    let source = RouteTimeline()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func timeline() async throws -> Timeline { source }
    override func id() -> String { "!route:test" }
}

@Suite("Bounded chat routes", .serialized)
@MainActor
struct ChatRouteTests {
    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    private func window(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.isHidden = false
        controller.view.layoutIfNeeded()
        return window
    }

    @Test("Only two chat contents survive while profile routes and complete back history remain")
    func residentBudget() throws {
        let root = UIViewController(), navigation = ZynaNavigationController()
        navigation.setStack([root], animated: false)
        let window = try window(navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        let chats = (0..<12).map { _ in RouteResident() }
        for chat in chats {
            navigation.push(UIViewController(), animated: false) // intervening profile
            navigation.push(chat, animated: false)
            #expect(chats.filter(\.resident).count <= 2)
        }
        #expect(navigation.stack.count == 25)
        #expect(chats.last?.visible == true)
        #expect(chats.dropLast().allSatisfy { !$0.visible })
        navigation.pop(to: chats[4], animated: false)
        #expect(navigation.stack.count == 11)
        #expect(chats[3].resident && chats[4].resident)
        #expect(chats[3].loads == 2)
        #expect(navigation.topViewController === chats[4])
    }

    @Test("Cancelling back keeps both chat contents; a queued stack replacement runs after cancellation")
    func cancelledBack() async throws {
        let root = UIViewController(), first = RouteResident(), second = RouteResident()
        let navigation = ZynaNavigationController(rootViewController: root)
        let window = try window(navigation)
        defer { window.isHidden = true; window.rootViewController = nil }
        navigation.push(first, animated: false)
        navigation.push(second, animated: false)
        let pan = RoutePan()
        func gesture(_ state: UIGestureRecognizer.State) {
            pan.simulatedState = state
            navigation.perform(NSSelectorFromString("handleInteractivePop:"), with: pan)
        }
        gesture(.began)
        pan.setTranslation(CGPoint(x: 90, y: 0), in: navigation.view)
        gesture(.changed)
        #expect(navigation.isTransitionInFlight && first.resident && second.resident)
        gesture(.cancelled)
        try await wait { !navigation.isTransitionInFlight }
        #expect(navigation.topViewController === second)
        #expect(second.visible && !first.visible)
        #expect(first.loads == 1 && second.loads == 1)

        gesture(.began)
        navigation.setStack([root, first], animated: false)
        let next = UIViewController()
        navigation.push(next, animated: false)
        #expect(navigation.topViewController === second)
        gesture(.cancelled)
        try await wait { !navigation.isTransitionInFlight && navigation.topViewController === next }
        navigation.pop(animated: false)
        #expect(first.visible && first.loads == 1)
    }

    @Test("Returning to an evicted chat restores the message and its exact viewport distance")
    func restoredViewport() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<600).map(TimelineWriteFixture.message))
        let audio = AudioPlayerService(), root = UIViewController()
        let navigation = ZynaNavigationController(rootViewController: root)
        let window = try window(navigation)
        defer { navigation.setStack([root], animated: false); window.isHidden = true; window.rootViewController = nil }
        let route = ChatRouteViewController(roomID: TimelineWriteFixture.roomID) { state in
            let model = ChatViewModel(testingRoomId: TimelineWriteFixture.roomID, dbQueue: database,
                window: MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database),
                mode: .normal, navigationAnchor: state?.anchor)
            let chat = ChatViewController(viewModel: model, audioPlayer: audio)
            chat.restoreNavigationState(state)
            model.prepareInitialHistoryWindow()
            return chat
        }
        navigation.push(route, animated: false)
        try await wait { route.chat?.node.list.layout.geometry.ids.count ?? 0 >= 200 }
        navigation.view.layoutIfNeeded()
        let anchor: ChatNavigationAnchor
        do {
            let chat = try #require(route.chat)
            chat.node.list.contentOffset.y = chat.node.list.layout.geometry.origins[130] - 17
            chat.node.list.view.layoutIfNeeded()
            anchor = try #require(chat.captureNavigationState().anchor)
        }
        navigation.push(RouteResident(), animated: false)
        navigation.push(RouteResident(), animated: false)
        #expect(route.chat == nil)
        navigation.pop(to: route)
        // Content must be recreated before the animation starts, not afterwards.
        #expect(route.chat != nil && navigation.isTransitionInFlight)
        try await wait {
            guard !navigation.isTransitionInFlight, let chat = route.chat else { return false }
            chat.view.layoutIfNeeded()
            let geometry = chat.node.list.layout.geometry
            guard let index = geometry.indices[anchor.listID] else { return false }
            let distance = geometry.origins[index] - chat.node.list.contentOffset.y - chat.node.list.contentInset.top
            return abs(distance - anchor.distance) < 1
        }
        #expect(route.chat?.captureNavigationState().anchor?.eventID == anchor.eventID)
    }

    @Test("An evicted chat releases its controller and restores formatted input and forwarding")
    func releasedChatAndDraft() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<12).map(TimelineWriteFixture.message))
        let audio = AudioPlayerService(), root = UIViewController()
        let navigation = ZynaNavigationController(rootViewController: root)
        let window = try window(navigation)
        defer { navigation.setStack([root], animated: false); window.isHidden = true; window.rootViewController = nil }
        let forward = try #require(TimelineWriteFixture.message(7).toChatMessage())
        let initialText = ComposerText(body: "Draft stays", formattedBody: "<strong>Draft</strong> stays")
        var constructed: [RouteWeakChat] = []
        let routes = (0..<4).map { index in
            ChatRouteViewController(roomID: "!route-\(index):test") { state in
                let model = ChatViewModel(testingRoomId: TimelineWriteFixture.roomID, dbQueue: database,
                    window: MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database), mode: .normal)
                let chat = ChatViewController(viewModel: model, audioPlayer: audio)
                var initial = ChatNavigationState()
                initial.text = initialText
                initial.selection = NSRange(location: 3, length: 2)
                initial.search = .init(query: "Message", eventID: forward.eventId)
                initial.composer.photoGroupCaptionPlacement = .top
                chat.restoreNavigationState(state ?? initial)
                constructed.append(RouteWeakChat(chat))
                return chat
            }
        }
        navigation.push(routes[0], animated: false)
        try await wait { routes[0].chat?.captureNavigationState().text == initialText }
        routes[0].setPendingForward(forward)
        for route in routes.dropFirst() { navigation.push(route, animated: false) }
        #expect(routes[0].chat == nil && routes[1].chat == nil)
        try await wait { constructed[0].value == nil }
        #expect(navigation.returnToChat(roomID: routes[0].roomIdentifier, animated: false))
        let restored = try #require(routes[0].chat)
        try await wait { restored.captureNavigationState().forward?.eventId == forward.eventId }
        #expect(restored.captureNavigationState().text == initialText)
        #expect(restored.captureNavigationState().selection == NSRange(location: 3, length: 2))
        #expect(restored.captureNavigationState().search?.query == "Message")
        #expect(restored.captureNavigationState().search?.eventID == forward.eventId)
        #expect(restored.captureNavigationState().composer.photoGroupCaptionPlacement == .top)
        #expect(navigation.stack.count == 2)

        let another = try #require(TimelineWriteFixture.message(8).toChatMessage())
        #expect(navigation.returnToChat(roomID: routes[0].roomIdentifier, animated: false, forward: another))
        #expect(navigation.stack.count == 2 && routes[0].chat === restored)
        #expect(restored.captureNavigationState().forward?.eventId == another.eventId)
        #expect(!navigation.returnToChat(roomID: "!missing:test", animated: false))
    }

    @Test("Restoration reads around the event and falls back near its timestamp after deletion")
    func restoredWindow() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<600).map(TimelineWriteFixture.message))
        let roomID = TimelineWriteFixture.roomID
        let initial = MessageWindow(roomId: roomID, dbQueue: database)
        let request = initial.replacementRequest(.restoration(eventID: "$event-210", timestamp: 210))
        let page = try #require(try await Task.detached { try request.fetch() }.value)
        initial.applyReplacement(page)
        #expect(initial.currentStoredMessages().contains { $0.eventId == "$event-210" })
        #expect(initial.currentStoredMessages().count == 200)
        _ = try await database.write { try StoredMessage.filter(Column("eventId") == "$event-210").deleteAll($0) }
        let next = MessageWindow(roomId: roomID, dbQueue: database)
        let fallback = next.replacementRequest(.restoration(eventID: "$event-210", timestamp: 210))
        let restored = try #require(try await Task.detached { try fallback.fetch() }.value)
        next.applyReplacement(restored)
        #expect(next.currentStoredMessages().contains { $0.eventId == "$event-209" })
        #expect(!next.currentStoredMessages().contains { $0.eventId == "$event-599" })
    }

    @Test("Hidden presentation coalesces notifications and resumes once, preserving all provenance")
    func pausedRefresh() {
        var summaries: [TimelineFlushSummary] = []
        var complete: ((ChatTimelineRefreshQueue.Result) -> Void)?
        let queue = ChatTimelineRefreshQueue { summary, done in summaries.append(summary); complete = done }
        queue.setPaused(true)
        for _ in 0..<100 { queue.enqueue(.init(pushBackCount: 1)) }
        #expect(summaries.isEmpty)
        queue.setPaused(false)
        #expect(summaries.count == 1 && summaries[0].pushBackCount == 100)
        queue.setPaused(true)
        queue.enqueue(.init(setCount: 1))
        complete?(.superseded)
        #expect(summaries.count == 1)
        queue.setPaused(false)
        #expect(summaries.count == 2 && summaries[1].pushBackCount == 100 && summaries[1].setCount == 1)
        complete?(.applied)
        #expect(queue.isIdle)
    }

    @Test("An explicit jump winning restoration releases the pause on future live refreshes")
    func jumpWinsRestoration() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<600).map(TimelineWriteFixture.message))
        let model = ChatViewModel(testingRoomId: TimelineWriteFixture.roomID, dbQueue: database,
            window: MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database),
            navigationAnchor: .init(eventID: "$event-100", timestamp: 100, listID: "row-100", distance: 0))
        defer { model.cleanup() }
        model.prepareHistoryReplacement(.event("$event-300")) { $0() }
        model.prepareInitialHistoryWindow()
        try await wait { model.historyGeneration > 0 }
        #expect(model.messages.contains { $0.eventId == "$event-300" })
        #expect(!model.messages.contains { $0.eventId == "$event-100" })
        model.refreshPresentationForTesting(.init(setCount: 1))
        try await wait { model.isTimelineRefreshIdleForTesting }
    }

    @Test("Search keeps the selected event during restoration and ignores superseded background results")
    func restoredSearch() async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<50).map(TimelineWriteFixture.message))
        let model = ChatViewModel(testingRoomId: TimelineWriteFixture.roomID, dbQueue: database,
            window: MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database))
        defer { model.cleanup() }
        model.activateSearch()
        model.updateSearchQuery("Message", restoringEventID: "$event-7")
        #expect(model.navigationSearchState?.eventID == "$event-7")
        try await wait { model.searchState?.currentResult?.eventId == "$event-7" }
        model.updateSearchQuery("Message 1")
        model.updateSearchQuery("Message 2")
        #expect(model.searchState?.results.isEmpty == true)
        try await wait { model.searchState?.results.count == 11 }
        #expect(model.searchState?.results.allSatisfy { $0.body.contains("Message 2") } == true)
        model.updateSearchQuery("Message 3")
        model.deactivateSearch()
        model.activateSearch()
        try await model.drainPresentationWorkerForTesting()
        #expect(model.searchState?.query == "" && model.searchState?.results.isEmpty == true)
    }

    @Test("Stopping a timeline while its listener is starting cancels the late handle")
    func stoppedListener() async throws {
        let room = RouteRoom(), handle = RouteListenerHandle(noHandle: .init())
        let service = TimelineService(room: room)
        let start = Task { await service.startListening(subscribeForSync: false) }
        try await wait { await room.source.request.isPending }
        service.stopListening()
        await room.source.request.finish(handle)
        await start.value
        #expect(handle.cancellations.wrappedValue == 1)
        #expect(!service.hasLiveTimeline)
    }
}
