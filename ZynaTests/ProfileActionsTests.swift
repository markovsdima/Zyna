// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK
import Testing
@testable import Zyna

private final class LinkTestRoom: Room, @unchecked Sendable {
    let reads = Atomic(0)
    let link: String
    init(_ link: String) { self.link = link; super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func matrixToPermalink() async throws -> String {
        reads.modify { $0 += 1 }
        return link
    }
}

private final class TopicTestSource: RoomTopicSource, @unchecked Sendable {
    struct State {
        var snapshot = RoomTopicSnapshot(topic: "Original", canEdit: true)
        var read: ProfileTestRequest<RoomTopicSnapshot>?
        var write: ProfileTestRequest<Void>?
        var failRead = false
        var failSave = false
        var writes: [String] = []
    }
    let state = Atomic(State())
    let callback = Atomic<(@Sendable (RoomTopicSnapshot) -> Void)?>(nil)
    func load() async throws -> RoomTopicSnapshot {
        let value = state.wrappedValue
        if value.failRead { throw URLError(.notConnectedToInternet) }
        if let request = value.read { return try await request.wait() }
        return value.snapshot
    }
    func save(_ topic: String) async throws {
        state.modify { $0.writes.append(topic) }
        if let request = state.wrappedValue.write { try await request.wait() }
        if state.wrappedValue.failSave { throw URLError(.notConnectedToInternet) }
        state.modify { $0.snapshot.topic = topic }
    }
    func observe(_ update: @escaping @Sendable (RoomTopicSnapshot) -> Void) -> RoomProfileObservation {
        callback.wrappedValue = update
        return RoomProfileObservation { [weak self] in self?.callback.wrappedValue = nil }
    }
    func send(_ value: RoomTopicSnapshot) {
        state.modify { $0.snapshot = value }
        callback.wrappedValue?(value)
    }
}

@Suite("Profile links and descriptions", .serialized)
@MainActor
struct ProfileActionsTests {
    private func wait(_ predicate: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await predicate(), sourceLocation: sourceLocation)
    }

    @Test("User links round-trip identifiers through the SDK, including reserved characters",
          arguments: ["@alice:example.org", "@a/b:example.org", "@alice:example.org:8448"])
    func personLinks(userID: String) async throws {
        let url = try await MatrixLinkTarget.person(userID).url()
        let parsed = try #require(parseMatrixEntityFrom(uri: url.absoluteString))
        #expect(parsed.id == .user(id: userID))
        await #expect(throws: (any Error).self) { try await MatrixLinkTarget.person("not a Matrix ID").url() }
    }

    @Test("Room links preserve aliases and routing servers supplied by the SDK",
          arguments: ["https://matrix.to/#/%23group:example.org", "https://matrix.to/#/!room:example.org?via=a.org&via=b.org"])
    func roomLinks(value: String) async throws {
        let room = LinkTestRoom(value)
        #expect(try await MatrixLinkTarget.room(room).url().absoluteString == value)
        #expect(room.reads.wrappedValue == 1)
    }

    @Test("Repeated share taps use one request; leaving or changing accounts suppresses late delivery", arguments: [false, true])
    func cancelledSharing(switchAccount: Bool) async throws {
        let gate = ProfileTestRequest<URL>(), reads = Atomic(0)
        var active = true, deliveries = 0
        let model = MatrixLinkSharing(isCurrentSession: { active }, resolve: { _ in
            reads.modify { $0 += 1 }; return try await gate.wait()
        })
        model.prepare(.person("@alice:example.org")) { _ in deliveries += 1 }
        try await wait { await gate.isPending }
        model.prepare(.person("@bob:example.org")) { _ in deliveries += 1 }
        if switchAccount { active = false } else { model.cancel() }
        await gate.finish(try #require(URL(string: "https://matrix.to/#/@alice:example.org")))
        await model.waitForOperationForTesting()
        #expect(deliveries == 0 && reads.wrappedValue == 1 && !model.isPreparing)
    }

    @Test("Failed sharing can retry and delivers the new result once")
    func shareRetry() async throws {
        let fail = Atomic(true)
        let expected = try #require(URL(string: "https://matrix.to/#/@alice:example.org"))
        let model = MatrixLinkSharing(isCurrentSession: { true }, resolve: { _ in
            if fail.wrappedValue { throw URLError(.notConnectedToInternet) }; return expected
        })
        var result: URL?
        model.prepare(.person("@alice:example.org")) { result = $0 }
        await model.waitForOperationForTesting()
        #expect(model.error != nil && result == nil && !model.isPreparing)
        fail.wrappedValue = false
        model.prepare(.person("@alice:example.org")) { result = $0 }
        await model.waitForOperationForTesting()
        #expect(model.error == nil && result == expected)
    }

    @Test("Live description changes preserve drafts, and failed saves retain multiline text for retry")
    func topicDraft() async throws {
        let source = TopicTestSource()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        source.send(.init(topic: "Remote", canEdit: true))
        try await wait { model.draft == "Remote" }
        let draft = "Первая строка\n\nhttps://example.org 🐾"
        model.draft = draft
        source.send(.init(topic: "Other edit", canEdit: true))
        try await wait { model.snapshot?.topic == "Other edit" }
        #expect(model.draft == draft)
        source.state.modify { $0.failSave = true }
        var saved: String?
        model.onSaved = { saved = $0 }
        model.save(); model.save()
        await model.waitForOperationsForTesting()
        #expect(model.draft == draft && model.error != nil && saved == nil && model.canSave)
        #expect(source.state.wrappedValue.writes == [draft])
        source.state.modify { $0.failSave = false }
        model.save()
        await model.waitForOperationsForTesting()
        #expect(saved == draft && model.error == nil && !model.canSave)
    }

    @Test("Saving rechecks topic permission and never writes after it is revoked")
    func revokedPermission() async throws {
        let source = TopicTestSource()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        model.draft = "Draft"
        source.state.modify { $0.snapshot.canEdit = false }
        model.save()
        await model.waitForOperationsForTesting()
        #expect(model.snapshot?.canEdit == false && !model.isSaving && model.draft == "Draft")
        #expect(source.state.wrappedValue.writes.isEmpty)
    }

    @Test("A late permission read cannot override a revocation delivered during save")
    func staleSaveRead() async throws {
        let source = TopicTestSource(), gate = ProfileTestRequest<RoomTopicSnapshot>()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        model.draft = "Draft"
        source.state.modify { $0.read = gate }
        model.save()
        try await wait { await gate.isPending }
        source.send(.init(topic: "Original", canEdit: false))
        try await wait { model.snapshot?.canEdit == false }
        await gate.finish(.init(topic: "Original", canEdit: true))
        await model.waitForOperationsForTesting()
        #expect(source.state.wrappedValue.writes.isEmpty && model.snapshot?.canEdit == false)
    }

    @Test("Description saves trim only outer whitespace and retain paragraph formatting",
          arguments: ["  \nText\n\nParagraph  \n", "  \n\t"])
    func trimmedTopic(draft: String) async throws {
        let source = TopicTestSource()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        model.draft = draft
        model.save(); await model.waitForOperationsForTesting()
        let expected = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(source.state.wrappedValue.writes == [expected])
        #expect(model.draft == expected && !model.canSave)
    }

    @Test("An empty description removes the topic")
    func removeTopic() async throws {
        let source = TopicTestSource()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        model.draft = ""; model.save()
        await model.waitForOperationsForTesting()
        #expect(source.state.wrappedValue.writes == [""] && model.snapshot?.topic == "")
    }

    @Test("Account changes or closing the editor while checking permissions prevent a write", arguments: [false, true])
    func invalidatedTopicSave(stop: Bool) async throws {
        let source = TopicTestSource(), gate = ProfileTestRequest<RoomTopicSnapshot>()
        var active = true, saved = false
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { active })
        model.onSaved = { _ in saved = true }
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        model.draft = "Draft"
        source.state.modify { $0.read = gate }
        model.save()
        try await wait { await gate.isPending }
        if stop { model.stop() } else { active = false }
        await gate.finish(.init(topic: "Original", canEdit: true))
        await model.waitForOperationsForTesting()
        #expect(source.state.wrappedValue.writes.isEmpty && !saved)
    }

    @Test("A subscription snapshot wins over an older initial read; initial network failures can retry")
    func initialTopicRead() async throws {
        let source = TopicTestSource(), gate = ProfileTestRequest<RoomTopicSnapshot>()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        source.state.modify { $0.failRead = true }
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        #expect(model.error != nil && !model.isLoading && model.snapshot == nil)
        source.state.modify { $0.failRead = false; $0.read = gate }
        model.reload()
        try await wait { await gate.isPending }
        source.send(.init(topic: "Latest", canEdit: true))
        try await wait { model.draft == "Latest" }
        await gate.finish(.init(topic: "Stale", canEdit: true))
        await model.waitForOperationsForTesting()
        #expect(model.draft == "Latest" && model.error == nil && !model.isLoading)
    }

    @Test("A save accepted before a lost response is recognized on retry without another write")
    func acceptedTopicRetry() async throws {
        let source = TopicTestSource()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        model.start(); defer { model.stop() }
        await model.waitForOperationsForTesting()
        model.draft = "Confirmed on server"
        source.state.modify { $0.failSave = true }
        model.save()
        await model.waitForOperationsForTesting()
        source.state.modify { $0.snapshot.topic = "Confirmed on server"; $0.failSave = false }
        var saved = false
        model.onSaved = { _ in saved = true }
        model.save()
        await model.waitForOperationsForTesting()
        #expect(saved && source.state.wrappedValue.writes.count == 1 && model.error == nil)
    }

    @Test("A late write completion cannot navigate after the editor closes")
    func closedDuringTopicWrite() async throws {
        let source = TopicTestSource(), gate = ProfileTestRequest<Void>()
        let model = RoomTopicEditorModel(source: source, isCurrentSession: { true })
        var saved = false
        model.onSaved = { _ in saved = true }
        model.start()
        await model.waitForOperationsForTesting()
        source.state.modify { $0.write = gate }
        model.draft = "Sent"; model.save()
        try await wait { await gate.isPending }
        model.stop()
        await gate.finish(())
        await model.waitForOperationsForTesting()
        #expect(!saved && source.state.wrappedValue.writes == ["Sent"])
    }
}
