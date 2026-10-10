//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK
import Network
import Testing
@testable import Zyna

/// Exercises the linked XCFramework and UniFFI, including Rust poll aggregation.
/// The SDK talks only to an ephemeral loopback server with synthetic events.
@Suite("Poll SDK integration", .serialized)
struct PollSDKIntegrationTests {
    @Test("The linked inspection API repairs relations but retains visible, unknown and encrypted events",
          .timeLimit(.minutes(1)))
    func inspectedPlaceholderRepair() async throws {
        let server = try PollSDKServer()
        let url = try await server.start()
        defer { server.stop() }
        let client = try await ClientBuilder().homeserverUrl(url: url).inMemoryStore()
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 3_000,
                maxConcurrentRequests: nil, maxRetryTime: nil)).build()
        try await client.restoreSession(session: Session(accessToken: "local-test-token", refreshToken: nil,
            userId: PollSDKServer.userID, deviceId: "LOCAL_TEST", homeserverUrl: url,
            oauthData: nil, slidingSyncVersion: .none))
        let room = try await client.joinRoomById(roomId: PollSDKServer.roomID)
        // Without the creation state, room-version-dependent classification
        // must remain indeterminate rather than guessing a hidden event.
        #expect(try await room.inspectTimelineEvent(eventId: "$vote").disposition == .indeterminate)
        _ = try await client.syncOnceV2(settings: .init(timeoutMs: 0, fullState: true))
        let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
            focus: .event(eventId: "$poll", numContextEvents: 10, threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all, internalIdPrefix: nil, dateDividerMode: .daily,
            trackReadReceipts: .disabled, reportUtds: false))
        _ = timeline // Keep the ordinary room timeline/cache alive during inspection.
        let expected: [(String, RoomTimelineEventDisposition)] = [
            ("$vote", .hidden), ("$end", .hidden), ("$edit2", .hidden),
            ("$reaction", .hidden), ("$text-edit", .hidden), ("$call-candidates", .hidden),
            ("$poll", .visible), ("$literal", .visible), ("$custom", .indeterminate),
            ("$unsupported", .indeterminate), ("$malformed", .indeterminate),
            ("$missing-keys", .unableToDecrypt)
        ]
        let messages = expected.enumerated().map { index, value -> StoredMessage in
            var message = TimelineWriteFixture.message(index)
            message.roomId = PollSDKServer.roomID
            message.senderId = PollSDKServer.userID
            message.eventId = value.0
            message.contentBody = "Не удалось расшифровать сообщение"
            return message
        }
        let database = try TimelineWriteFixture.database(legacyMessages: messages)
        let candidates = try await database.read {
            try MessageDecryptionRepairStore.candidates(in: $0, roomID: PollSDKServer.roomID, now: 1000, limit: 20)
        }
        #expect(candidates.count == expected.count)
        for candidate in candidates {
            let id = try #require(candidate.message.eventId)
            let result = try await room.inspectTimelineEvent(eventId: id)
            #expect(result.disposition == expected.first { $0.0 == id }?.1, "Wrong disposition for \(id)")
            #expect(result.event.roomId == PollSDKServer.roomID && result.event.eventId == id)
            #expect((result.decryptionFailure != nil) == (result.disposition == .unableToDecrypt))
            try await database.write { db in
                _ = try MessageDecryptionRepairStore.apply(result, to: candidate, in: db, now: 1000)
                let stored = try StoredMessage.fetchOne(db, key: candidate.message.id)
                #expect((stored == nil) == (result.disposition == .hidden))
                if id == "$missing-keys" { #expect(stored?.decryptionFailure != nil) }
                if id == "$literal" { #expect(stored?.contentType == "text") }
            }
        }
        await #expect(throws: ClientError.self) { try await room.inspectTimelineEvent(eventId: "$absent") }
        // This endpoint is unrelated to the room's loaded timeline: no per-ID
        // focused timelines or /context requests are created by inspection.
        #expect(server.requests.filter { $0.contains("/context/") }.count == 1)
    }

    @Test("An actual SDK decryption failure persists as typed state", .timeLimit(.minutes(1)))
    func typedDecryptionPlaceholder() async throws {
        let server = try PollSDKServer()
        let url = try await server.start()
        defer { server.stop() }
        let client = try await ClientBuilder().homeserverUrl(url: url).inMemoryStore()
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 3_000,
                maxConcurrentRequests: nil, maxRetryTime: nil)).build()
        try await client.restoreSession(session: Session(accessToken: "local-test-token", refreshToken: nil,
            userId: PollSDKServer.userID, deviceId: "LOCAL_TEST", homeserverUrl: url,
            oauthData: nil, slidingSyncVersion: .none))
        let room = try await client.joinRoomById(roomId: PollSDKServer.roomID)
        let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
            focus: .event(eventId: "$missing-keys", numContextEvents: 0,
                threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all, internalIdPrefix: nil, dateDividerMode: .daily,
            trackReadReceipts: .disabled, reportUtds: false))
        let database = try TimelineWriteFixture.database()
        let batcher = TimelineDiffBatcher(roomId: PollSDKServer.roomID, dbQueue: database)
        let listener = PollSDKListener(didUpdate: { batcher.receive(diffs: $0) })
        let handle = await timeline.addListener(listener: listener)
        defer { handle.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while listener.decryptionItem == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let item = try #require(listener.decryptionItem)
        let recoverySDK = MessageProjectionRecovery.SDK(timeline: timeline)
        #expect(try await recoverySDK.session("$missing-keys", PollSDKServer.userID) == "missing-session")
        #expect(try await recoverySDK.session("$missing-keys", "@wrong:example.org") == nil)
        #if DEBUG
        let live = try await timeline.getEventTimelineItemByEventId(eventId: "$missing-keys")
        #expect(TimelineService.messageDiagnosticProjection(live) == .projectionUTD)
        // A miss is a memory-only lookup, not an event/context fetch.
        let readsBefore = server.requests.filter { $0.contains("/event/") || $0.contains("/context/") }
        do {
            _ = try await timeline.getEventTimelineItemByEventId(eventId: "$not-in-timeline")
            Issue.record("Missing event unexpectedly found")
        } catch ClientError.Generic(let message, _) {
            #expect(message == "Item with given event ID not found")
        }
        #expect(server.requests.filter { $0.contains("/event/") || $0.contains("/context/") } == readsBefore)
        #endif
        let message = try #require(TimelineService.mapTimelineItem(item))
        #expect(message.content.isUnableToDecrypt)
        #expect(message.content.textBody == nil)
        await batcher.synchronize()
        let row = try #require(try await database.read { db in
            try StoredMessage.filter(Column("eventId") == "$missing-keys").fetchOne(db)
        })
        #expect(row.contentType == "unableToDecrypt")
        #expect(row.decryptionFailure != nil)
        #expect(!row.isLegacyDecryptionCandidate)
        #expect(try #require(row.toChatMessage()).content == message.content)
        let candidate = try #require(try await database.read {
            try MessageDecryptionRepairStore.candidates(in: $0, roomID: row.roomId,
                                                        now: Date().timeIntervalSince1970).first
        })
        _ = try await database.write {
            try MessageDecryptionRepairStore.apply(nil, to: candidate, in: $0,
                                                   now: Date().timeIntervalSince1970 + 3600)
        }
        // The real SDK item's UTD identity survives positional bookkeeping.
        // A removal wakes inspection but does not itself delete the DB row.
        batcher.receive(diffs: [.clear])
        await batcher.synchronize()
        let retried = try await database.read {
            try MessageDecryptionRepairStore.candidates(in: $0, roomID: row.roomId,
                                                        now: Date().timeIntervalSince1970)
        }
        #expect(retried.first?.message == row)
    }

    @Test("The real SDK aggregates polls and exposes the effective edit with either timeline filter",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func latestPollEditJSON(filtered: Bool) async throws {
        let server = try PollSDKServer()
        let url = try await server.start()
        defer { server.stop() }
        let client = try await ClientBuilder().homeserverUrl(url: url).inMemoryStore()
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 3_000,
                maxConcurrentRequests: nil, maxRetryTime: nil)).build()
        try await client.restoreSession(session: Session(accessToken: "local-test-token", refreshToken: nil,
            userId: PollSDKServer.userID, deviceId: "LOCAL_TEST", homeserverUrl: url,
            oauthData: nil, slidingSyncVersion: .none))
        let room = try await client.joinRoomById(roomId: PollSDKServer.roomID)
        _ = try await client.syncOnceV2(settings: .init(timeoutMs: 0, fullState: true))
        let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
            focus: .event(eventId: "$poll", numContextEvents: 10, threadMode: .automatic(hideThreadedEvents: false)),
            filter: filtered ? SDKRoomPollHistorySource.filter : .all, internalIdPrefix: nil, dateDividerMode: .daily,
            trackReadReceipts: .disabled, reportUtds: false))
        let database = try TimelineWriteFixture.database()
        let batcher = TimelineDiffBatcher(roomId: PollSDKServer.roomID, dbQueue: database)
        let listener = PollSDKListener(didUpdate: { batcher.receive(diffs: $0) })
        let task = await timeline.addListener(listener: listener)
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var completedItem: TimelineItem?
        while true {
            // Updates may arrive in separate batches. Capture the exact item
            // satisfying the final SDK state and assert against that snapshot.
            if let candidate = listener.pollItem, let event = candidate.asEvent(),
               case .msgLike(let message) = event.content,
               case .poll(_, _, _, _, _, let endTime, _) = message.kind, endTime != nil,
               let json = event.lazyProvider.debugInfo().latestEditJson,
               let raw = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               raw["event_id"] as? String == "$edit2" {
                completedItem = candidate
                break
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let item = try #require(completedItem, "No ended poll with $edit2 received; requests: \(server.requests)")
        let event = try #require(item.asEvent())
        #expect(try await MessageProjectionRecovery.SDK(timeline: timeline).session("$poll", event.sender) == nil)
        #if DEBUG
        let live = try await timeline.getEventTimelineItemByEventId(eventId: "$poll")
        #expect(TimelineService.messageDiagnosticProjection(live) == .projectionMapped)
        #endif
        let json = try #require(event.lazyProvider.debugInfo().latestEditJson)
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(raw["event_id"] as? String == "$edit2")
        let message = try #require(TimelineService.mapTimelineItem(item))
        guard case .poll(let poll) = message.content else {
            Issue.record("The SDK poll must map to a poll bubble")
            return
        }
        #expect(poll.isEdited)
        #expect(poll.definition.question == "Second edit")
        #expect(poll.latestEditEventID == "$edit2")
        #expect(message.latestEditEventId == "$edit2")
        // A response and end after the edit must preserve its identity.
        #expect(poll.hasEnded)
        #expect(poll.totalVoters == 1)
        #if DEBUG
        // These events exist but are aggregated away from the UI timeline.
        // The diagnostic must identify them through the linked SDK binding.
        for (id, expected) in [("$vote", "org.matrix.msc3381.poll.response"),
                               ("$end", "org.matrix.msc3381.poll.end")] {
            await #expect(throws: ClientError.self) {
                try await timeline.getEventTimelineItemByEventId(eventId: id)
            }
            let related = try await room.inspectTimelineEvent(eventId: id)
            #expect(related.disposition == .hidden)
            #expect(related.event.eventType == expected)
        }
        #endif
        await batcher.synchronize()
        try await database.read { db throws -> Void in
            let stored = try #require(try StoredMessage.filter(Column("contentType") == "poll").fetchOne(db))
            let snapshot = try #require(PollCoding.decode(PollSnapshot.self, from: stored.contentPollJSON))
            #expect(snapshot.hasEnded && snapshot.latestEditEventID == "$edit2")
            #expect(try StoredRoomPoll.fetchCount(db) == 1)
        }
    }

    @Test("Poll attachments discover old polls and retain missing-key events through the real SDK",
          .timeLimit(.minutes(1)))
    @MainActor
    func pollHistoryPagination() async throws {
        let server = try PollSDKServer()
        let url = try await server.start()
        defer { server.stop() }
        let client = try await ClientBuilder().homeserverUrl(url: url).inMemoryStore()
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 3_000,
                maxConcurrentRequests: nil, maxRetryTime: nil)).build()
        try await client.restoreSession(session: Session(accessToken: "local-test-token", refreshToken: nil,
            userId: PollSDKServer.userID, deviceId: "LOCAL_TEST", homeserverUrl: url,
            oauthData: nil, slidingSyncVersion: .none))
        let room = try await client.joinRoomById(roomId: PollSDKServer.roomID)
        let database = try RoomPollFixture.database()
        let catalog = RoomPollCatalog(roomId: PollSDKServer.roomID, database: database)
        let source = RecordingPollHistory(SDKRoomPollHistorySource(room: room, userID: PollSDKServer.userID, catalog: catalog))
        let model = RoomPollsViewModel(catalog: catalog, source: source, fillBudget: 3)
        defer { model.stop() }
        model.activate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while model.state != .exhausted, ContinuousClock.now < deadline {
            if case .failed = model.state { break }
            if model.state == .more { model.loadMore() }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.state == .exhausted, "State: \(model.state); batches: \(source.batches.suffix(8)); requests: \(server.requests)")
        let poll = try #require(model.items.first?.snapshot)
        #expect(model.items.count == 1)
        #expect(poll.definition.question == "Second edit")
        #expect(poll.latestEditEventID == "$edit2")
        #expect(poll.totalVoters == 1 && poll.selectedAnswerIDs == ["park"])
        #expect(poll.hasEnded)
        #expect(model.pendingDecryptionCount == 1)
        #expect(server.requests.contains { $0.contains("/messages") })
    }
}

@MainActor
private final class RecordingPollHistory: RoomPollHistorySource {
    var onChange: ((RoomPollHistoryState) -> Void)?
    var batches: [String] = []
    private var snapshot = RoomPollHistoryState()
    private let source: RoomPollHistorySource
    init(_ source: RoomPollHistorySource) {
        self.source = source
        source.onChange = { [weak self] state in
            self?.snapshot = state
            self?.onChange?(state)
        }
    }
    func start() async throws { try await source.start() }
    func loadMore() async throws -> Bool {
        let before = snapshot
        let end = try await source.loadMore()
        batches.append("end=\(end) rows=\(before.rowCount)->\(snapshot.rowCount) gen=\(before.generation)->\(snapshot.generation)")
        return end
    }
    func synchronize() async throws { try await source.synchronize() }
    func retryDecryption() { source.retryDecryption() }
    func stop() { source.stop() }
}

private final class PollSDKListener: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var storedItem: TimelineItem?
    private var storedDecryptionItem: TimelineItem?
    private let didUpdate: ([TimelineDiff]) -> Void
    var pollItem: TimelineItem? { lock.withLock { storedItem } }
    var decryptionItem: TimelineItem? { lock.withLock { storedDecryptionItem } }

    init(didUpdate: @escaping ([TimelineDiff]) -> Void = { _ in }) { self.didUpdate = didUpdate }

    func onUpdate(diff: [TimelineDiff]) {
        didUpdate(diff)
        for change in diff {
            let items: [TimelineItem]
            switch change {
            case .append(let values), .reset(let values): items = values
            case .pushBack(let value), .pushFront(let value), .insert(_, let value), .set(_, let value): items = [value]
            default: items = []
            }
            for item in items {
                if case .msgLike(let message) = item.asEvent()?.content,
                   case .unableToDecrypt = message.kind {
                    lock.withLock { storedDecryptionItem = item }
                }
                if case .msgLike(let message) = item.asEvent()?.content,
                   case .poll = message.kind {
                    lock.withLock { storedItem = item }
                }
            }
        }
    }
}

private final class PollSDKServer: @unchecked Sendable {
    static let roomID = "!sdk-poll:example.org"
    static let userID = "@alice:example.org"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.zyna.tests.poll-sdk-http")
    private let lock = NSLock()
    private var requestPaths: [String] = []
    var requests: [String] { lock.withLock { requestPaths } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 65_536 else { connection.cancel(); return }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: buffer[..<range.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let contentLength = lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffer.count - range.upperBound >= contentLength {
                    let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    self.respond(connection, path: path.removingPercentEncoding ?? path)
                    return
                }
            }
            guard !complete else { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        lock.withLock { requestPaths.append(path) }
        let body: Any
        let status: Int
        if path.contains("/versions") {
            body = ["versions": ["v1.11"], "unstable_features": [:]] as [String: Any]
            status = 200
        } else if path.contains("/sync?") || path.hasSuffix("/sync") {
            let create: [String: Any] = ["event_id": "$create", "type": "m.room.create", "state_key": "",
                "sender": Self.userID, "origin_server_ts": 1,
                "content": ["creator": Self.userID, "room_version": "10"]]
            let member: [String: Any] = ["event_id": "$join", "type": "m.room.member", "state_key": Self.userID,
                "sender": Self.userID, "origin_server_ts": 2, "content": ["membership": "join"]]
            body = ["next_batch": "inspection-state", "rooms": ["join": [Self.roomID: [
                "state": ["events": [create, member]],
                "timeline": ["events": [], "limited": false, "prev_batch": "inspection-state"]]]]] as [String: Any]
            status = 200
        } else if path.hasSuffix("/join") || path.contains("/join/") {
            body = ["room_id": Self.roomID]
            status = 200
        } else if path.contains("/context/$poll") {
            body = Self.context()
            status = 200
        } else if path.contains("/context/$missing-keys") {
            body = ["event": Self.encryptedEvent(), "events_before": [], "events_after": [],
                    "state": Self.context()["state"] ?? []] as [String: Any]
            status = 200
        } else if path.contains("/event/") {
            let context = Self.context()
            let candidates = [context["event"] as! [String: Any]] + (context["events_after"] as! [[String: Any]])
                + Self.inspectionEvents() + [Self.encryptedEvent()]
            let id = String(path.split(separator: "/").last ?? "")
            if let event = candidates.first(where: { $0["event_id"] as? String == id }) {
                body = event
                status = 200
            } else {
                body = ["errcode": "M_NOT_FOUND", "error": "No fixture event"]
                status = 404
            }
        } else if path.contains("/messages") {
            if path.contains("from=") {
                body = ["start": "poll-history-start", "chunk": []] as [String: Any]
            } else {
                let context = Self.context()
                let poll = context["event"] as! [String: Any]
                let related = context["events_after"] as! [[String: Any]]
                body = ["start": "latest", "end": "poll-history-start",
                        "chunk": [Self.encryptedEvent()] + related.reversed() + [poll]] as [String: Any]
            }
            status = 200
        } else {
            body = ["errcode": "M_NOT_FOUND", "error": "No fixture for this endpoint"]
            status = 404
        }
        do {
            let json = try JSONSerialization.data(withJSONObject: body)
            var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(json)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        } catch { connection.cancel() }
    }

    private static func encryptedEvent() -> [String: Any] {
        ["event_id": "$missing-keys", "type": "m.room.encrypted", "sender": userID,
         "origin_server_ts": 105_000,
         "content": ["algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AAAA",
             "session_id": "missing-session", "sender_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
             "device_id": "OTHER"]]
    }

    private static func inspectionEvents() -> [[String: Any]] {
        func event(_ id: String, _ type: String, _ content: [String: Any]) -> [String: Any] {
            ["event_id": id, "room_id": roomID, "sender": userID, "type": type,
             "origin_server_ts": 106_000, "content": content]
        }
        return [
            event("$literal", "m.room.message", ["msgtype": "m.text", "body": "Не удалось расшифровать сообщение"]),
            event("$text-edit", "m.room.message", ["msgtype": "m.text", "body": "* Edited",
                "m.new_content": ["msgtype": "m.text", "body": "Edited"],
                "m.relates_to": ["rel_type": "m.replace", "event_id": "$literal"]]),
            event("$reaction", "m.reaction", ["m.relates_to": ["rel_type": "m.annotation", "event_id": "$literal", "key": "x"]]),
            event("$call-candidates", "m.call.candidates", ["call_id": "test-call", "version": 0, "candidates": []]),
            event("$custom", "com.example.future", ["body": "Unknown event"]),
            event("$unsupported", "m.room.message", ["msgtype": "com.example.future", "body": "Unknown message"]),
            event("$malformed", "m.reaction", ["unexpected": "Malformed event"])
        ]
    }

    private static func context() -> [String: Any] {
        func event(_ id: String, _ type: String, _ content: [String: Any], _ timestamp: Int) -> [String: Any] {
            ["event_id": id, "type": type, "sender": userID, "room_id": roomID,
             "origin_server_ts": timestamp, "content": content]
        }
        func content(_ question: String) -> [String: Any] {
            ["org.matrix.msc1767.text": question,
             "org.matrix.msc3381.poll.start": [
                "question": ["org.matrix.msc1767.text": question],
                "kind": "org.matrix.msc3381.poll.disclosed", "max_selections": 1,
                "answers": [["id": "park", "org.matrix.msc1767.text": "Park"],
                            ["id": "cafe", "org.matrix.msc1767.text": "Café"]]]]
        }
        func edit(_ id: String, _ question: String, _ timestamp: Int) -> [String: Any] {
            var value = content(question)
            value["m.new_content"] = content(question)
            value["m.relates_to"] = ["rel_type": "m.replace", "event_id": "$poll"]
            return event(id, "org.matrix.msc3381.poll.start", value, timestamp)
        }
        let reference = ["rel_type": "m.reference", "event_id": "$poll"]
        return [
            "event": event("$poll", "org.matrix.msc3381.poll.start", content("Original"), 100_000),
            "events_before": [],
            "events_after": [
                edit("$edit1", "First edit", 101_000), edit("$edit2", "Second edit", 102_000),
                event("$vote", "org.matrix.msc3381.poll.response", [
                    "m.relates_to": reference, "org.matrix.msc3381.poll.response": ["answers": ["park"]]], 103_000),
                event("$end", "org.matrix.msc3381.poll.end", [
                    "m.relates_to": reference, "org.matrix.msc3381.poll.end": [:], "org.matrix.msc1767.text": "Ended"], 104_000)
            ],
            "state": []
        ]
    }
}
