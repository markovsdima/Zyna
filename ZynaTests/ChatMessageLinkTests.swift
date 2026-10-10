// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK
import Testing
@testable import Zyna

private final class MessageLinkTestRoom: Room, @unchecked Sendable {
    let calls = Atomic<[(eventID: String, onMain: Bool)]>([])
    let permalink: String

    init(permalink: String) { self.permalink = permalink; super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }

    override func matrixToEventPermalink(eventId: String) async throws -> String {
        calls.modify { $0.append((eventId, Thread.isMainThread)) }
        return permalink
    }
}

@Suite("Message links")
@MainActor
struct ChatMessageLinkTests {
    @Test("Own and incoming server events can be linked before and after sync",
          arguments: [false, true], ["sent", "synced", "read"])
    func confirmedMessages(outgoing: Bool, status: String) throws {
        var record = TimelineWriteFixture.message(1)
        record.isOutgoing = outgoing
        record.sendStatus = status
        let message = try #require(record.toChatMessage())
        #expect(ChatMessageLink.targets(for: message) == [.init(eventID: "$event-1", photoIndex: nil)])
        #expect(ChatMessageLink.target(for: message, selectedItem: nil)?.eventID == "$event-1")
    }

    @Test("Local echoes, failed sends and invalid event IDs never expose a permalink",
          arguments: [nil, "", "$", "transaction-1"] as [String?])
    func localMessages(eventID: String?) throws {
        var record = TimelineWriteFixture.message(1)
        record.eventId = eventID
        record.transactionId = "transaction-1"
        for status in ["sending", "failed"] {
            record.sendStatus = status
            let message = try #require(record.toChatMessage())
            #expect(ChatMessageLink.targets(for: message).isEmpty)
        }
    }

    @Test("Album menus target the selected event; VoiceOver retains each photo's position")
    func albums() throws {
        var message = try #require(TimelineWriteFixture.message(1).toChatMessage())
        let items = [item("first", eventID: "$first"), item("pending", eventID: nil),
                     item("third", eventID: "$third")]
        message.mediaGroupPresentation = .init(id: "album", position: .top, totalHint: 3,
            caption: "Caption", captionPlacement: .bottom, layoutOverride: nil,
            suppressIndividualCaption: true, items: items,
            rendersCompositeBubble: true, hidesStandaloneBubble: false)
        #expect(ChatMessageLink.targets(for: message) == [
            .init(eventID: "$first", photoIndex: 0), .init(eventID: "$third", photoIndex: 2)
        ])
        #expect(ChatMessageLink.target(for: message, selectedItem: items[2])?.eventID == "$third")
        #expect(ChatMessageLink.target(for: message, selectedItem: items[1]) == nil)
        // Caption/overflow presses must not fall back to the representative event.
        #expect(ChatMessageLink.target(for: message, selectedItem: nil) == nil)
        #expect(ChatMessageLink.target(for: message, selectedItem: item("other", eventID: "$other")) == nil)
        message.outgoingEnvelopeId = "outgoing"
        #expect(ChatMessageLink.targets(for: message).isEmpty)
        message.outgoingEnvelopeId = nil
        message.incomingAssemblyId = "assembly"
        #expect(ChatMessageLink.targets(for: message).isEmpty)
    }

    @Test("SDK event permalinks preserve routing hints and reopen the same event off-main",
          arguments: ["!room:example.org", "#alias:example.org"])
    func eventPermalink(reference: String) async throws {
        let permalink = "https://matrix.to/#/\(reference.replacingOccurrences(of: "#", with: "%23"))/$chosen?via=a.org&via=b.org"
        let room = MessageLinkTestRoom(permalink: permalink)
        let url = try await MatrixLinkTarget.event(room: room, eventID: "$chosen").url()
        #expect(url.absoluteString == permalink)
        #expect(MatrixLink.parse(url) == .room(.init(reference: reference, via: ["a.org", "b.org"], eventID: "$chosen")))
        #expect(room.calls.wrappedValue.count == 1)
        #expect(room.calls.wrappedValue.first?.eventID == "$chosen")
        #expect(room.calls.wrappedValue.first?.onMain == false)
    }

    @Test("The latest copy wins even if an earlier SDK request ignores cancellation")
    func lateCopy() async throws {
        let old = ProfileTestRequest<URL>()
        let expected = try #require(URL(string: "https://matrix.to/#/!room:example.org/$new"))
        let model = MatrixLinkSharing(isCurrentSession: { true }, resolve: { target in
            if case .event(_, "$old") = target { return try await old.wait() }
            return expected
        })
        let room = MessageLinkTestRoom(permalink: expected.absoluteString)
        var deliveries: [URL] = []
        model.prepare(.event(room: room, eventID: "$old")) { deliveries.append($0) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await old.isPending), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await old.isPending)
        let oldOperation = try #require(model.operationForTesting)
        model.prepare(.event(room: room, eventID: "$new"), replacingPending: true) { deliveries.append($0) }
        await model.waitForOperationForTesting()
        await old.finish(try #require(URL(string: "https://matrix.to/#/!room:example.org/$old")))
        await oldOperation.value
        #expect(deliveries == [expected])
        #expect(!model.isPreparing && model.error == nil)
    }

    private func item(_ id: String, eventID: String?) -> MediaGroupItem {
        .init(messageId: id, eventId: eventID, transactionId: eventID == nil ? id : nil,
              source: nil, thumbnailSource: nil, previewImageData: nil, previewIdentity: nil,
              width: nil, height: nil, blurhash: nil, sizeBytes: nil, caption: nil,
              sendStatus: eventID == nil ? "sending" : "synced")
    }
}
