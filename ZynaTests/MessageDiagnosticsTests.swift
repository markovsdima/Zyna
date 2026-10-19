//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import GRDB
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("Message decryption diagnostics")
struct MessageDiagnosticsTests {
    @Test("A retained placeholder can be distinguished from an aggregated poll response without modifying storage")
    @MainActor
    func stalePlaceholderReport() async throws {
        let database = try TimelineWriteFixture.database()
        var row = TimelineWriteFixture.message(0)
        row.contentBody = "Не удалось расшифровать сообщение"
        row.senderId = "@private-sender:example.org"
        row.contentFormattedBody = "private-formatted-body"
        let original = row
        try await database.write { try original.insert($0) }
        let request = MessageDiagnostics.Request(database: database, roomID: row.roomId,
            rowID: row.id, eventID: row.eventId, displayedPlaceholder: true)
        let report = await MessageDiagnostics.collect(request,
            history: ["map kind=utd", "remove (DB row retained)"], liveLookup: { _ in
                Self.expectBackgroundThread()
                throw ClientError.Generic(msg: "Item with given event ID not found", details: "private-error-detail")
            }, eventLookup: { id in
                Self.expectBackgroundThread()
                return Self.inspection(id: id)
            })
        #expect(report.text.contains("placeholderTextMatch=true"))
        #expect(report.text.contains("sdk.live=not-in-current-timeline"))
        #expect(report.text.contains("sdk.inspection disposition=hidden type=\"org.matrix.msc3381.poll.response\""))
        #expect(report.text.contains("remove (DB row retained)"))
        for secret in [original.senderId, original.contentBody!, original.contentFormattedBody!, "private-error-detail"] {
            #expect(!report.text.contains(secret))
        }
        #expect(try await database.read { try StoredMessage.fetchOne($0, key: original.id) } == original)
    }

    @Test("JSON inspection exports only metadata, not payload or encryption material")
    func safeMetadata() throws {
        let raw: [String: Any] = ["type": "m.room.encrypted", "sender": "PRIVATE_SENDER",
            "content": ["body": "PRIVATE_BODY", "ciphertext": "PRIVATE_CIPHERTEXT",
                "sender_key": "PRIVATE_KEY", "session_id": "PRIVATE_SESSION",
                "algorithm": "m.megolm.v1.aes-sha2",
                "m.relates_to": ["rel_type": "m.reference", "event_id": "$poll"]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        let metadata = MessageDiagnostics.metadata(json).joined(separator: "\n")
        #expect(metadata.contains("m.room.encrypted"))
        #expect(metadata.contains("m.reference"))
        #expect(metadata.contains("$poll"))
        #expect(!metadata.contains("PRIVATE_"))
        #expect(MessageDiagnostics.metadata("broken json") == ["json=unavailable"])
    }

    @Test("A retired account stops inspection before any SDK request")
    func retiredAccount() async throws {
        let database = try TimelineWriteFixture.database()
        let request = MessageDiagnostics.Request(database: database, roomID: "room",
            rowID: "row", eventID: "$event", displayedPlaceholder: true)
        try await Task.detached { try database.close() }.value
        let report = await MessageDiagnostics.collect(request, history: [], liveLookup: { _ in
            Issue.record("An old account made a timeline lookup")
            throw CancellationError()
        }, eventLookup: { id in
            Issue.record("An old account made an event lookup")
            return Self.inspection(id: id)
        })
        #expect(report.text.contains("db.error=account-retired"))
        #expect(report.text.contains("accountActiveAtEnd=false"))
    }

    @Test("Repair summaries distinguish embedded call signals using the chat mapper's carrier rules")
    func repairCallCarrier() throws {
        let formatted = ZynaHTMLCodec.encode(userHTML: "PRIVATE_BODY", attributes: .init(
            callSignal: .init(type: "m.call.candidates", payload: "PRIVATE_PAYLOAD")))
        for type in ["m.text", "m.image", "m.audio", "m.file", "m.video", "m.notice", "m.emote"] {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: [
                "msgtype": type, "body": "PRIVATE_BODY", "formatted_body": formatted
            ]), as: UTF8.self)
            let count = MessageDiagnostics.repairContentCount(Self.inspection(
                id: "$private-event", type: "m.room.message", disposition: .visible, content: json))
            #expect(count == (["m.notice", "m.emote"].contains(type) ? .visibleText : .visibleZynaCall))
            #expect(count?.rawValue.contains("PRIVATE_") == false)
        }
    }

    @Test("Repair summaries retain useful categories for ordinary and malformed content")
    func repairContentCategories() {
        let samples: [(String, String, HistoryPerformanceTrace.Count)] = [
            ("m.room.message", #"{"msgtype":"m.text","formatted_body":"<span data-zyna='broken'></span>"}"#, .visibleText),
            ("m.room.message", #"{"msgtype":"m.image","body":"PRIVATE_BODY"}"#, .visibleMedia),
            ("org.matrix.msc3381.poll.start", "{}", .visiblePoll),
            ("org.matrix.msc4075.rtc.notification", "{}", .visibleRTC),
            ("m.room.message", #"{"msgtype":"m.text","body":"\u200b \n"}"#, .visibleEmptyText),
            ("m.call.invite", #"{"call_id":"private-call","offer":{"type":"offer","sdp":"private-sdp"}}"#, .visibleCallInvite),
            ("m.room.message", "broken json", .visibleOther),
            ("PRIVATE_CUSTOM_TYPE", "{}", .visibleOther)
        ]
        for (type, content, expected) in samples {
            #expect(MessageDiagnostics.repairContentCount(Self.inspection(
                id: "$private-event", type: type, disposition: .visible, content: content)) == expected)
        }
    }

    @Test("Repair summaries preserve unknown outcomes and never classify hidden events as visible")
    func repairUnknownCategories() {
        #expect(MessageDiagnostics.repairContentCount(Self.inspection(id: "$event",
            type: "m.room.encrypted", disposition: .indeterminate)) == .unknownEncrypted)
        #expect(MessageDiagnostics.repairContentCount(Self.inspection(id: "$event",
            type: "PRIVATE_CUSTOM_TYPE", disposition: .indeterminate)) == .unknownOther)
        for disposition in [RoomTimelineEventDisposition.hidden, .unableToDecrypt] {
            #expect(MessageDiagnostics.repairContentCount(Self.inspection(id: "$event",
                type: "m.room.message", disposition: disposition, content: #"{"msgtype":"m.text"}"#)) == nil)
        }
    }

    @Test("SDK errors never leak their payload into the diagnostic")
    func lookupErrorPrivacy() async throws {
        let database = try TimelineWriteFixture.database()
        let request = MessageDiagnostics.Request(database: database, roomID: "room", rowID: "row",
                                                  eventID: "$event", displayedPlaceholder: false)
        let report = await MessageDiagnostics.collect(request, history: [], liveLookup: nil, eventLookup: { _ in
            throw ClientError.Generic(msg: "PRIVATE_PAYLOAD", details: "PRIVATE_TOKEN")
        })
        #expect(!report.text.contains("PRIVATE_"))
        #expect(report.text.contains("sdk.event=lookup-error:"))
        #expect(!report.text.contains("not-in-current-timeline"))
    }

    @Test("Indeterminate samples expose only allowlisted types and field shapes, with bounded deduplication")
    func unknownSamples() throws {
        var samples = MessageUnknownDiagnostics()
        let content = #"{"msgtype":"PRIVATE_MSGTYPE","body":"PRIVATE_BODY","m.relates_to":{"rel_type":"PRIVATE_RELATION","event_id":"$PRIVATE_TARGET"},"PRIVATE_KEY":"PRIVATE_VALUE"}"#
        let result = Self.inspection(id: "$PRIVATE_EVENT", type: "m.room.message",
                                     disposition: .indeterminate, content: content)
        let first = samples.sample(result, attempt: 4)
        let line = try #require(first)
        #expect(line.contains("type=m.room.message"))
        #expect(line.contains("msgtype=custom:"))
        #expect(line.contains("relation=custom:"))
        #expect(line.contains("body:string"))
        #expect(line.contains("m.relates_to:object"))
        #expect(line.contains("attempt=4"))
        #expect(!line.contains("PRIVATE_"))
        #expect(!line.contains(result.event.roomId))
        #expect(samples.sample(result, attempt: 5) == nil)
        #expect(samples.sample(Self.inspection(id: "$visible", disposition: .visible), attempt: 1) == nil)
        for index in 1..<8 {
            let next = samples.sample(Self.inspection(id: "$event-\(index)",
                type: "PRIVATE_EVENT_TYPE", disposition: .indeterminate, content: "broken json"), attempt: 1)
            let custom = try #require(next)
            #expect(custom.contains("type=custom:"))
            #expect(custom.contains("contentJSON=false"))
            #expect(!custom.contains("PRIVATE_"))
        }
        #expect(samples.sample(Self.inspection(id: "$overflow", disposition: .indeterminate), attempt: 1) == nil)
    }

    @Test("Indeterminate samples distinguish malformed message shapes and redacted state envelopes")
    func unknownShapes() throws {
        var samples = MessageUnknownDiagnostics()
        var result = Self.inspection(id: "$state", type: "m.room.encrypted", disposition: .indeterminate,
                                    content: #"{"msgtype":"m.text","body":null,"m.relates_to":[]}"#)
        result.event.rawJson = #"{"state_key":"PRIVATE_STATE","unsigned":{"redacted_because":{"content":"PRIVATE_REDACTION"}}}"#
        let first = samples.sample(result, attempt: 1)
        let line = try #require(first)
        #expect(line.contains("stateKey=string"))
        #expect(line.contains("redacted=true"))
        #expect(line.contains("msgtype=m.text"))
        #expect(line.contains("body:null"))
        #expect(line.contains("m.relates_to:array"))
        #expect(!line.contains("PRIVATE_"))
    }

    @Test("The diagnostic ring remains bounded and returns only this event and window changes")
    func historyBounds() {
        var history = MessageDiagnosticHistory()
        history.record("evicted", eventID: "$event")
        for i in 0..<300 { history.record("other-\(i)", eventID: "$other") }
        history.record("reset incoming=3")
        history.record("map kind=utd", eventID: "$event")
        history.record("remove (DB row retained)", eventID: "$event")
        let snapshot = history.snapshot(eventID: "$event")
        #expect(snapshot.count == 3)
        #expect(!snapshot.joined().contains("evicted"))
        #expect(!snapshot.joined().contains("other-"))
        for i in 0..<20 { history.record("map \(i)", eventID: "$event") }
        #expect(history.snapshot(eventID: "$event").count == 12)
    }

    @Test("Projection sampling skips exclusions, deduplicates retries and caps lookups without logging payloads")
    func projectionProbeBounds() async throws {
        let database = try TimelineWriteFixture.database()
        let lines = Atomic<[String]>([])
        let calls = Atomic(0)
        let trace = HistoryPerformanceTrace.Session(roomID: TimelineWriteFixture.roomID,
            database: database, interval: nil, output: { line in lines.modify { $0.append(line) } })
        defer { trace.stop() }
        let probe = MessageProjectionDiagnostics(roomID: TimelineWriteFixture.roomID, trace: trace) { _ in
            Self.expectBackgroundThread()
            calls.modify { $0 += 1 }
            throw ClientError.Generic(msg: "Item with given event ID not found", details: "PRIVATE_DETAILS")
        }
        for index in 0..<40 {
            let id = "$PRIVATE_EVENT_\(index)"
            await probe.record(Self.inspection(id: id), requestedID: id) // Hidden.
            await probe.record(Self.inspection(id: id, type: "m.room.message", disposition: .visible,
                content: #"{"msgtype":"m.text","body":" "}"#), requestedID: id) // App exclusion.
        }
        #expect(calls.wrappedValue == 0)
        for index in 0..<100 {
            let id = "$PRIVATE_EVENT_\(index)"
            let result = Self.inspection(id: id, type: "m.room.message", disposition: .visible,
                content: #"{"msgtype":"m.text","body":"PRIVATE_BODY"}"#)
            await probe.record(result, requestedID: "$wrong-id")
            await probe.record(result, requestedID: id)
            await probe.record(result, requestedID: id)
        }
        #expect(calls.wrappedValue == 32)
        await probe.recheckAfterPagination(delay: .zero)
        await probe.recheckAfterPagination(delay: .zero)
        #expect(calls.wrappedValue == 64)
        trace.flush()
        #expect(lines.wrappedValue.contains { $0.contains("projectionAbsent=32") })
        #expect(lines.wrappedValue.contains { $0.contains("projectionCapped=1") })
        #expect(lines.wrappedValue.contains { $0.contains("projectionRecheckAbsent=32") })
        #expect(!lines.wrappedValue.joined().contains("PRIVATE_"))
    }

    @Test("Projection sampling distinguishes lookup failures and stops with its trace")
    func projectionProbeError() async throws {
        let database = try TimelineWriteFixture.database()
        let lines = Atomic<[String]>([])
        let calls = Atomic(0)
        let trace = HistoryPerformanceTrace.Session(roomID: TimelineWriteFixture.roomID,
            database: database, interval: nil, output: { line in lines.modify { $0.append(line) } })
        let probe = MessageProjectionDiagnostics(roomID: TimelineWriteFixture.roomID, trace: trace) { _ in
            calls.modify { $0 += 1 }
            throw ClientError.Generic(msg: "PRIVATE_ERROR", details: "PRIVATE_DETAILS")
        }
        func visible(_ id: String) -> RoomTimelineEventInspection {
            Self.inspection(id: id, type: "m.room.message", disposition: .visible,
                content: #"{"msgtype":"m.text","body":"PRIVATE_BODY"}"#)
        }
        await probe.record(visible("$one"), requestedID: "$one")
        trace.flush()
        trace.stop()
        await probe.record(visible("$two"), requestedID: "$two")
        await probe.recheckAfterPagination(delay: .zero)
        #expect(calls.wrappedValue == 1)
        #expect(lines.wrappedValue.contains { $0.contains("projectionError=1") })
        #expect(!lines.wrappedValue.joined().contains("PRIVATE_"))
    }

    private static func expectBackgroundThread() {
        #expect(!Thread.isMainThread)
    }

    private static func inspection(id: String, type: String = "org.matrix.msc3381.poll.response",
                                   disposition: RoomTimelineEventDisposition = .hidden,
                                   content: String = "private-content") -> RoomTimelineEventInspection {
        .init(event: .init(roomId: TimelineWriteFixture.roomID,
            eventType: type, eventId: id,
            sender: "@private-sender:example.org", originServerTsMs: 1000,
            contentJson: content, rawJson: "{}", encryptionInfo: nil),
            disposition: disposition, decryptionFailure: nil)
    }
}
#endif
