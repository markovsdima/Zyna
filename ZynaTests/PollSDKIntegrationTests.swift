//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK
import Network
import Testing
@testable import Zyna

/// Exercises the linked XCFramework and UniFFI, including Rust poll aggregation.
/// The SDK talks only to an ephemeral loopback server with synthetic events.
@Suite("Poll SDK integration", .serialized)
struct PollSDKIntegrationTests {
    @Test("The real SDK exposes the effective poll edit ID through latestEditJson", .timeLimit(.minutes(1)))
    func latestPollEditJSON() async throws {
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
            focus: .event(eventId: "$poll", numContextEvents: 10, threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all, internalIdPrefix: nil, dateDividerMode: .daily,
            trackReadReceipts: .disabled, reportUtds: false))
        let listener = PollSDKListener()
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
    }
}

private final class PollSDKListener: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var storedItem: TimelineItem?
    var pollItem: TimelineItem? { lock.withLock { storedItem } }

    func onUpdate(diff: [TimelineDiff]) {
        for change in diff {
            let items: [TimelineItem]
            switch change {
            case .append(let values), .reset(let values): items = values
            case .pushBack(let value), .pushFront(let value), .insert(_, let value), .set(_, let value): items = [value]
            default: items = []
            }
            for item in items {
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
        } else if path.hasSuffix("/join") || path.contains("/join/") {
            body = ["room_id": Self.roomID]
            status = 200
        } else if path.contains("/context/$poll") {
            body = Self.context()
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
