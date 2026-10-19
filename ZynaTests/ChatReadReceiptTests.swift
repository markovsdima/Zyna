// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private final class ReceiptHandle: TaskHandle, @unchecked Sendable {
    override func cancel() {}
}

private final class ReceiptTimeline: Timeline, @unchecked Sendable {
    struct Receipt: Equatable {
        let type: ReceiptType
        let eventID: String
    }
    let receipts = Atomic<[Receipt]>([])
    let failRead = Atomic(false)
    private enum InjectedFailure: Error { case read }
    let readGate: ProfileTestRequest<Void>?
    init(holdRead: Bool = false) {
        readGate = holdRead ? ProfileTestRequest() : nil
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func addListener(listener: any TimelineListener) async -> TaskHandle { ReceiptHandle(noHandle: .init()) }
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool { true }
    override func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws {
        receipts.modify { $0.append(.init(type: receiptType, eventID: eventId)) }
        if receiptType == .read, failRead.wrappedValue { throw InjectedFailure.read }
        if receiptType == .read, let readGate { try await readGate.wait() }
    }
}

private final class ReceiptRoom: Room, @unchecked Sendable {
    let source: ReceiptTimeline
    init(holdRead: Bool = false) {
        source = ReceiptTimeline(holdRead: holdRead)
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func timeline() async throws -> Timeline { source }
    override func id() -> String { TimelineWriteFixture.roomID }
}

@Suite("Read receipts on chat departure", .serialized)
@MainActor
struct ChatReadReceiptTests {
    @Test("A failed public receipt cannot be acknowledged by a successful fully-read marker")
    func failedRead() async throws {
        let room = ReceiptRoom(), service = TimelineService(room: room)
        await service.startListening(subscribeForSync: false)
        defer { service.stopListening() }
        let request = try #require(service.readReceiptRequest(for: "$viewed"))
        room.source.failRead.wrappedValue = true
        #expect(await request.send() == false)
        #expect(room.source.receipts.wrappedValue == [.init(type: .read, eventID: "$viewed")])
        room.source.failRead.wrappedValue = false
        #expect(await request.send() == true)
        #expect(room.source.receipts.wrappedValue == [
            .init(type: .read, eventID: "$viewed"),
            .init(type: .read, eventID: "$viewed"), .init(type: .fullyRead, eventID: "$viewed")])
    }

    @Test("A cached visible message is evaluated again when the SDK timeline becomes ready", arguments: [false, true])
    func timelineReadiness(hidden: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<50).map(TimelineWriteFixture.message))
        let room = ReceiptRoom(), service = TimelineService(room: room)
        let model = model(database, service)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { chat.finishNavigationSession(); window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        model.prepareInitialHistoryWindow()
        try await wait { chat.node.list.layout.geometry.ids.count >= 50 }
        chat.node.list.contentOffset.y = -chat.node.list.view.adjustedContentInset.top
        chat.scrollViewDidScroll(chat.node.list.view)
        // Let both viewport and receipt debounce expire before readiness.
        try await Task.sleep(for: .milliseconds(600))
        #expect(room.source.receipts.wrappedValue.isEmpty)
        if hidden { chat.setNavigationContentVisible(false, prepareWhileHidden: true) }
        await service.startListening(subscribeForSync: false)
        if hidden {
            try await Task.sleep(for: .milliseconds(400))
            #expect(room.source.receipts.wrappedValue.isEmpty)
            chat.setNavigationContentVisible(true)
        }
        // No scrolling, data update or reopening is allowed to wake the receipt.
        try await wait { room.source.receipts.wrappedValue.count == 2 }
        #expect(room.source.receipts.wrappedValue == [
            .init(type: .read, eventID: "$event-49"), .init(type: .fullyRead, eventID: "$event-49")])
    }

    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    private func model(_ database: AccountDatabase, _ service: TimelineService,
                       mode: ChatPresentationMode = .normal) -> ChatViewModel {
        ChatViewModel(testingRoomId: TimelineWriteFixture.roomID, dbQueue: database,
            window: MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database),
            mode: mode, timelineService: service)
    }

    @Test("Hiding or closing flushes the latest viewed target exactly once", arguments: [false, true], [false, true])
    func departure(close: Bool, prepareWhileHidden: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let room = ReceiptRoom(holdRead: true), service = TimelineService(room: room)
        await service.startListening(subscribeForSync: false)
        let model = model(database, service)
        defer { model.cleanup() }
        model.updateVisibleReadReceiptCandidate(eventId: "$older", canEstablishBaseline: true)
        model.updateVisibleReadReceiptCandidate(eventId: "$viewed", canEstablishBaseline: true)
        #expect(room.source.receipts.wrappedValue.isEmpty)
        model.setNavigationPresentationActive(false, prepareWhileHidden: prepareWhileHidden)
        if close { model.cleanup() }
        let gate = try #require(room.source.readGate)
        try await wait { await gate.isPending }
        model.flushPendingReadReceipt()
        model.updateVisibleReadReceiptCandidate(eventId: "$unseen", canEstablishBaseline: true)
        model.flushPendingReadReceipt()
        #expect(room.source.receipts.wrappedValue == [.init(type: .read, eventID: "$viewed")])
        await gate.finish(())
        try await wait { room.source.receipts.wrappedValue.count == 2 }
        #expect(room.source.receipts.wrappedValue == [
            .init(type: .read, eventID: "$viewed"), .init(type: .fullyRead, eventID: "$viewed")])
    }

    @Test("A final receipt survives immediate timeline cleanup without retaining the model")
    func releasedModel() async throws {
        let database = try TimelineWriteFixture.database()
        let room = ReceiptRoom(holdRead: true), service = TimelineService(room: room)
        #expect(service.readReceiptRequest(for: "$viewed") == nil)
        await service.startListening(subscribeForSync: false)
        var model: ChatViewModel? = model(database, service)
        let isReleased = { [weak model] in model == nil }
        model?.updateVisibleReadReceiptCandidate(eventId: "$viewed", canEstablishBaseline: true)
        model?.cleanup()
        model = nil
        #expect(isReleased())
        #expect(!service.hasLiveTimeline)
        #expect(service.readReceiptRequest(for: "$viewed") == nil)
        let gate = try #require(room.source.readGate)
        try await wait { await gate.isPending }
        await gate.finish(())
        try await wait { room.source.receipts.wrappedValue.count == 2 }
        #expect(room.source.receipts.wrappedValue.last == .init(type: .fullyRead, eventID: "$viewed"))
    }

    @Test("Leaving before the scroll debounce resolves the actual viewport", arguments: [false, true])
    func viewport(close: Bool) async throws {
        let database = try TimelineWriteFixture.database(legacyMessages: (0..<50).map(TimelineWriteFixture.message))
        let room = ReceiptRoom(), service = TimelineService(room: room)
        await service.startListening(subscribeForSync: false)
        let model = model(database, service)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        // Prepare without marking anything read while the route is merely warm.
        chat.setNavigationContentVisible(false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { chat.finishNavigationSession(); window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        model.prepareInitialHistoryWindow()
        try await wait { chat.node.list.layout.geometry.ids.count >= 50 }
        chat.view.layoutIfNeeded()
        chat.node.list.contentOffset.y = -chat.node.list.contentInset.top
        chat.node.list.view.layoutIfNeeded()
        #expect(room.source.receipts.wrappedValue.isEmpty)

        chat.setNavigationContentVisible(true)
        chat.scrollViewDidScroll(chat.node.list.view)
        #expect(room.source.receipts.wrappedValue.isEmpty)
        if close { chat.finishNavigationSession() }
        else { chat.setNavigationContentVisible(false) }
        try await wait { room.source.receipts.wrappedValue.count == 2 }
        #expect(room.source.receipts.wrappedValue == [
            .init(type: .read, eventID: "$event-49"), .init(type: .fullyRead, eventID: "$event-49")])
    }

    @Test("Previews and a historical viewport without a baseline never create a departure receipt",
          arguments: [false, true])
    func noUnseenReceipt(preview: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let room = ReceiptRoom(), service = TimelineService(room: room)
        await service.startListening(subscribeForSync: false)
        let model = model(database, service, mode: preview ? .preview : .normal)
        model.updateVisibleReadReceiptCandidate(eventId: "$not-viewed", canEstablishBaseline: preview)
        model.setNavigationPresentationActive(false)
        model.cleanup()
        #expect(room.source.receipts.wrappedValue.isEmpty)
    }
}
