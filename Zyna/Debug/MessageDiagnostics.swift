//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import GRDB
import MatrixRustSDK

/// Explicit, read-only inspection of one bubble. Never exports message bodies,
/// raw JSON, ciphertext, keys, or SDK error descriptions containing payloads.
enum MessageDiagnostics {
    struct Request: Sendable {
        let database: AccountDatabase
        let roomID: String
        let rowID: String
        let eventID: String?
        let displayedPlaceholder: Bool
    }

    struct Report: Sendable {
        let summary: String
        let lines: [String]
        var text: String { lines.joined(separator: "\n") }
    }

    static func placeholderTextMatches(_ body: String?) -> Bool {
        // A heuristic, not proof of UTD: legacy rows contain only localized
        // text. Include both shipped languages even after a language change.
        ChatDecryptionFailure.isLegacyPlaceholderText(body)
    }

    static func collect(
        _ request: Request, history: [String],
        liveLookup: (@Sendable (String) async throws -> EventTimelineItem)?,
        eventLookup: (@Sendable (String) async throws -> RoomTimelineEventInspection)?
    ) async -> Report {
        let run = String(UUID().uuidString.prefix(8))
        var lines = ["MessageDiag v2 request=\(run)",
            "db=\(PollCacheDiagnostics.databaseKey(request.database.path)) room=\(PollCacheDiagnostics.key(request.roomID))",
            "selected event=\(quoted(request.eventID)) row=\(PollCacheDiagnostics.key(request.rowID)) displayedPlaceholderTextMatch=\(request.displayedPlaceholder)"]
        var dbStatus = "unknown"
        var liveStatus = "not-requested"
        var fetchedStatus = "not-requested"
        do {
            let rows = try await request.database.read { db in
                var predicate = Column("id") == request.rowID
                if let eventID = request.eventID { predicate = predicate || Column("eventId") == eventID }
                return try StoredMessage.filter(Column("roomId") == request.roomID && predicate)
                    .order(Column("id")).limit(6).fetchAll(db)
            }
            dbStatus = rows.isEmpty ? "missing" : "\(rows.count) row(s)"
            lines.append("db.matchingRows=\(rows.count) limit=6")
            for row in rows {
                lines.append("db.row id=\(PollCacheDiagnostics.key(row.id)) event=\(quoted(row.eventId)) type=\(quoted(row.contentType)) typedDecryptionFailure=\(row.decryptionFailure?.rawValue ?? "none") placeholderTextMatch=\(placeholderTextMatches(row.contentBody)) timestamp=\(row.timestamp) sender=\(PollCacheDiagnostics.key(row.senderId)) outgoing=\(row.isOutgoing)")
            }
        } catch { dbStatus = errorLabel(error); lines.append("db.error=\(dbStatus)") }

        lines.append("recentDiffs=\(history.count) scope=current-batcher bounded=true")
        lines += history.map { "diff \($0)" }
        if let eventID = request.eventID, request.database.isActive, !Task.isCancelled {
            if let liveLookup {
                do {
                    let event = try await liveLookup(eventID)
                    liveStatus = "present:\(kind(event))"
                    lines.append("sdk.live=\(liveStatus) eventType=\(quoted(event.eventTypeRaw)) timestampMs=\(event.timestamp)")
                    lines += metadata(event.lazyProvider.debugInfo().originalJson).map { "sdk.original \($0)" }
                    if case .msgLike(let content) = event.content,
                       case .unableToDecrypt(let encrypted) = content.kind {
                        switch encrypted {
                        case .megolmV1AesSha2(let sessionID, let cause):
                            lines.append("sdk.utd algorithm=megolm session=\(PollCacheDiagnostics.key(sessionID)) cause=\(cause)")
                        case .olmV1Curve25519AesSha2: lines.append("sdk.utd algorithm=olm")
                        case .unknown: lines.append("sdk.utd algorithm=unknown")
                        }
                    }
                } catch {
                    liveStatus = liveErrorLabel(error)
                    lines.append("sdk.live=\(liveStatus)")
                }
            } else {
                liveStatus = "timeline-unavailable"
                lines.append("sdk.live=\(liveStatus)")
            }
            if let eventLookup, request.database.isActive, !Task.isCancelled {
                do {
                    let result = try await eventLookup(eventID)
                    fetchedStatus = "\(result.disposition):\(result.event.eventType)"
                    lines.append("sdk.inspection disposition=\(result.disposition) type=\(quoted(result.event.eventType)) id=\(quoted(result.event.eventId))")
                    if let failure = result.decryptionFailure {
                        lines.append("sdk.inspection.decryptionFailure=\(ChatDecryptionFailure(failure).rawValue)")
                    }
                    lines += metadata(result.event.rawJson).map { "sdk.inspection \($0)" }
                } catch {
                    fetchedStatus = "lookup-error:\(errorLabel(error))"
                    lines.append("sdk.event=\(fetchedStatus)")
                }
            }
        }
        lines.append("accountActiveAtEnd=\(request.database.isActive) cancelled=\(Task.isCancelled)")
        lines.append("note: absent from live timeline alone does not prove a stale row; the event may be outside its window. A text match alone does not prove a decryption failure.")
        let report = Report(summary: "DB: \(dbStatus)\nSDK timeline: \(liveStatus)\nSDK event: \(fetchedStatus)", lines: lines)
        if !Task.isCancelled {
            let log = ScopedLog(.messageDiagnostics, prefix: "[MessageDiag]")
            for line in lines { log("request=\(run) \(line)") }
        }
        return report
    }

    static func kind(_ event: EventTimelineItem) -> String {
        switch event.content {
        case .msgLike(let content):
            switch content.kind {
            case .unableToDecrypt: return "utd"
            case .message: return "message"
            case .poll: return "poll"
            case .redacted: return "redacted"
            default: return "other-message-like"
            }
        case .failedToParseMessageLike, .failedToParseState: return "parse-error"
        default: return "other-event"
        }
    }

    /// Classify an existing inspection result for aggregate timing logs.
    /// A fixed vocabulary prevents payloads or custom event types leaking.
    /// This is diagnostic metadata, never authorization to remove a row.
    static func repairContentCount(_ inspection: RoomTimelineEventInspection) -> HistoryPerformanceTrace.Count? {
        let event = inspection.event
        if inspection.disposition == .indeterminate {
            return event.eventType == "m.room.encrypted" ? .unknownEncrypted : .unknownOther
        }
        guard inspection.disposition == .visible else { return nil }
        switch ChatEventVisibility.exclusion(for: inspection) {
        case .zynaCallSignal: return .visibleZynaCall
        case .legacyCallInvite: return .visibleCallInvite
        case .emptyText: return .visibleEmptyText
        case .callReaction: return .visibleCall
        case nil: break
        }
        switch event.eventType {
        case "m.room.message":
            guard let content = try? JSONSerialization.jsonObject(with: Data(event.contentJson.utf8)) as? [String: Any],
                  let type = content["msgtype"] as? String else { return .visibleOther }
            switch type {
            case "m.text", "m.notice", "m.emote": return .visibleText
            case "m.image", "m.audio", "m.file", "m.video": return .visibleMedia
            default: return .visibleOther
            }
        case "org.matrix.msc3381.poll.start", "m.poll.start": return .visiblePoll
        case "org.matrix.msc4075.rtc.notification": return .visibleRTC
        case "m.call.invite", "m.call.answer", "m.call.candidates", "m.call.hangup",
             "m.call.reject", "m.call.negotiate", "m.call.select_answer", "m.call.asserted_identity",
             "m.call.sdp_stream_metadata_changed", "m.call.notify",
             "org.matrix.msc3401.call.member": return .visibleCall
        default: return .visibleOther
        }
    }

    static func metadata(_ json: String?) -> [String] {
        guard let json, let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return ["json=unavailable"]
        }
        let content = raw["content"] as? [String: Any] ?? [:]
        let relation = content["m.relates_to"] as? [String: Any] ?? [:]
        let unsigned = raw["unsigned"] as? [String: Any] ?? [:]
        return ["type=\(quoted(raw["type"] as? String)) relation=\(quoted(relation["rel_type"] as? String)) target=\(quoted(relation["event_id"] as? String)) redacted=\(unsigned["redacted_because"] != nil)",
                "algorithm=\(quoted(content["algorithm"] as? String)) session=\((content["session_id"] as? String).map(PollCacheDiagnostics.key) ?? "none")"]
    }

    private static func liveErrorLabel(_ error: Error) -> String {
        if case ClientError.Generic(let message, _) = error,
           message == "Item with given event ID not found" { return "not-in-current-timeline" }
        return "lookup-error:\(errorLabel(error))"
    }

    private static func errorLabel(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is AccountDatabase.AccessError { return "account-retired" }
        return String(reflecting: type(of: error))
    }

    private static func quoted(_ value: String?) -> String {
        value.map { String($0.prefix(200)).debugDescription } ?? "none"
    }
}

/// At most eight indeterminate events per worker lifetime, once each. Uses an
/// existing inspection result: no extra fetch, SQL, or timeline lookup.
struct MessageUnknownDiagnostics {
    private var sampled = Set<String>()

    mutating func sample(_ result: RoomTimelineEventInspection, attempt: Int) -> String? {
        guard result.disposition == .indeterminate, sampled.count < 8,
              let eventID = result.event.eventId, sampled.insert(eventID).inserted else { return nil }
        let event = result.event
        let content = try? JSONSerialization.jsonObject(with: Data(event.contentJson.utf8)) as? [String: Any]
        let raw = try? JSONSerialization.jsonObject(with: Data(event.rawJson.utf8)) as? [String: Any]
        let relation = content?["m.relates_to"] as? [String: Any]
        let unsigned = raw?["unsigned"] as? [String: Any]
        let fields = ["body", "msgtype", "m.relates_to", "m.new_content", "url", "file", "call_id", "offer", "emoji", "name",
                      "org.matrix.msc3381.poll.start", "org.matrix.msc3381.poll.response",
                      "org.matrix.msc3381.poll.end", "m.poll.start", "m.poll.response", "m.poll.end"]
            .compactMap { key -> String? in
                guard let value = content?[key] else { return nil }
                return "\(key):\(Self.shape(value))"
            }.joined(separator: ",")
        return [
            "room=\(PollCacheDiagnostics.key(event.roomId))", "event=\(PollCacheDiagnostics.key(eventID))",
            "attempt=\(attempt)", "type=\(Self.label(event.eventType))",
            "msgtype=\(Self.label(content?["msgtype"] as? String))",
            "relation=\(Self.label(relation?["rel_type"] as? String))",
            "rawJSON=\(raw != nil)", "contentJSON=\(content != nil)", "stateKey=\(Self.shape(raw?["state_key"]))",
            "redacted=\(unsigned?["redacted_because"] != nil)", "encryptionInfo=\(event.encryptionInfo != nil)",
            "fields=[\(fields)]", "sample=\(sampled.count)/8"
        ].joined(separator: " ")
    }

    /// Unknown technical strings are hashed too: event types and msgtypes are
    /// arbitrary sender-controlled strings, not guaranteed safe metadata.
    private static func label(_ value: String?) -> String {
        guard let value else { return "missing" }
        return knownTypes.contains(value) ? value : "custom:\(PollCacheDiagnostics.key(value))"
    }

    private static func shape(_ value: Any?) -> String {
        switch value {
        case nil: return "missing"
        case is String: return "string"
        case is [String: Any]: return "object"
        case is [Any]: return "array"
        case is NSNull: return "null"
        case is NSNumber: return "scalar"
        default: return "other"
        }
    }

    private static let knownTypes: Set<String> = [
        "m.room.message", "m.room.encrypted", "m.reaction", "m.room.redaction", "m.sticker",
        "m.room.member", "m.room.name", "m.room.topic", "m.room.avatar", "m.room.create",
        "m.room.power_levels", "m.room.encryption", "m.room.tombstone", "m.room.pinned_events",
        "m.text", "m.notice", "m.emote", "m.image", "m.video", "m.audio", "m.file", "m.location",
        "m.key.verification.request", "m.call.invite", "m.call.answer", "m.call.candidates",
        "m.call.hangup", "m.call.reject", "m.call.negotiate", "m.call.select_answer",
        "m.call.asserted_identity", "m.call.sdp_stream_metadata_changed", "m.call.notify",
        "org.matrix.msc3401.call.member", "org.matrix.msc4075.rtc.notification",
        "org.matrix.msc3381.poll.start", "org.matrix.msc3381.poll.response", "org.matrix.msc3381.poll.end",
        "m.poll.start", "m.poll.response", "m.poll.end", "m.annotation", "m.replace", "m.reference", "m.thread",
        "io.element.call.reaction"
    ]
}

/// Metadata-only ring, confined to the batcher's processing queue. It adds
/// no SQL, JSON parsing, or console logging to ordinary timeline processing.
struct MessageDiagnosticHistory {
    private struct Entry { let eventID: String?; let detail: String }
    private var entries = [Entry?](repeating: nil, count: 256)
    private var next = 0

    mutating func record(_ detail: String, eventID: String? = nil) {
        entries[next] = Entry(eventID: eventID, detail: "tMs=\(Int(ProcessInfo.processInfo.systemUptime * 1000)) \(detail)")
        next = (next + 1) % entries.count
    }

    func snapshot(eventID: String?) -> [String] {
        var matches: [String] = []
        for offset in 0..<entries.count {
            guard let entry = entries[(next + offset) % entries.count],
                  entry.eventID == eventID || entry.eventID == nil else { continue }
            matches.append(entry.detail)
        }
        return Array(matches.suffix(12))
    }
}
#endif
