//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("Typed message decryption state")
struct MessageDecryptionTests {
    @Test("Decryption failures persist as state, not localized or editable text")
    func typedRoundTrip() throws {
        let original = try #require(TimelineWriteFixture.message(0).toChatMessage())
        let message = ChatMessage(id: original.id, eventId: original.eventId, transactionId: nil,
            itemIdentifier: original.itemIdentifier, senderId: original.senderId,
            senderDisplayName: nil, senderAvatarUrl: nil, isOutgoing: true,
            timestamp: original.timestamp, content: .unableToDecrypt(.unavailable),
            reactions: [], replyInfo: nil, isEditable: false, isEdited: false,
            isEditPending: false, isEditFailed: false, latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced")
        let record = StoredMessage(from: message, roomId: TimelineWriteFixture.roomID)
        #expect(record.contentType == "unableToDecrypt")
        #expect(record.contentBody == "unavailable")
        #expect(!record.isLegacyDecryptionCandidate)
        let restored = try #require(record.toChatMessage())
        #expect(restored.content == .unableToDecrypt(.unavailable))
        #expect(restored.content.textBody == nil)
        #expect(!restored.isEditable && !restored.isTextEditable)
    }

    @Test("A label typed by a user stays ordinary text", arguments: [
        "Unable to decrypt message", "Не удалось расшифровать сообщение"
    ])
    func literalText(_ body: String) throws {
        var record = TimelineWriteFixture.message(0)
        record.contentBody = body
        #expect(record.isLegacyDecryptionCandidate)
        #expect(record.decryptionFailure == nil)
        #expect(try #require(record.toChatMessage()).content == .text(body: body))
    }

    @Test("A stale encrypted snapshot preserves a resolved projection", arguments: ["text", "image", "poll", "redacted"])
    func noDowngrade(_ type: String) async throws {
        let database = try TimelineWriteFixture.database()
        var resolved = TimelineWriteFixture.message(0)
        if type == "poll" {
            resolved = RoomPollFixture.poll("$event-0", ended: true).record!
            resolved.roomId = TimelineWriteFixture.roomID
        }
        resolved.contentType = type
        resolved.sendStatus = "read"
        resolved.senderDisplayName = "Alice"
        if type == "text" {
            resolved.contentBody = "Edited text"
            resolved.contentFormat = "org.matrix.custom.html"
            resolved.contentFormattedBody = "<strong>Edited text</strong>"
            resolved.latestEditEventId = "$edit"
            resolved.isEdited = true
            resolved.isEditPending = true
            resolved.pendingEditBody = "Next edit"
            resolved.replyEventId = "$parent"
        }
        if type == "image" {
            resolved.contentMediaJSON = "{\"url\":\"mxc://example.org/image\"}"
            resolved.contentImageWidth = 100
            resolved.contentImageHeight = 200
        }
        try await write(resolved, database: database)
        let id = resolved.id
        let before = try #require(try await database.read { try StoredMessage.fetchOne($0, key: id) })
        var stale = TimelineWriteFixture.message(0)
        stale.id = "new-sdk-identity"
        stale.timestamp = resolved.timestamp
        stale.isOutgoing = resolved.isOutgoing
        stale.contentType = "unableToDecrypt"
        stale.contentBody = "unavailable"
        try await write(stale, database: database)
        let after = try await database.read { try StoredMessage.fetchOne($0, key: id) }
        #expect(after == before)
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 1)
    }

    @Test("A successful decryption replaces the placeholder using its durable row identity")
    func resolvesInPlace() async throws {
        let database = try TimelineWriteFixture.database()
        var placeholder = TimelineWriteFixture.message(0)
        placeholder.contentType = "unableToDecrypt"
        placeholder.contentBody = "unavailable"
        try await write(placeholder, database: database)
        var resolved = TimelineWriteFixture.message(0)
        resolved.id = "different-sdk-id"
        resolved.contentBody = "Decrypted message"
        try await write(resolved, database: database)
        let row = try #require(try await database.read { try StoredMessage.fetchOne($0, key: "row-0") })
        #expect(row.contentBody == "Decrypted message")
        #expect(row.contentType == "text")
        #expect(try await database.read { try StoredMessage.fetchCount($0) } == 1)
    }

    @Test("Trust restrictions still replace cached plaintext; redaction remains terminal")
    func trustFailure() async throws {
        let database = try TimelineWriteFixture.database()
        try await write(TimelineWriteFixture.message(0), database: database)
        var restricted = TimelineWriteFixture.message(0)
        restricted.contentType = "unableToDecrypt"
        restricted.contentBody = "trustRequirement"
        try await write(restricted, database: database)
        let restrictedRow = try #require(try await database.read { try StoredMessage.fetchOne($0, key: "row-0") })
        #expect(restrictedRow.decryptionFailure == .trustRequirement)
        var redacted = TimelineWriteFixture.message(0)
        redacted.contentType = "redacted"
        try await write(redacted, database: database)
        try await write(restricted, database: database)
        #expect(try await database.read { try StoredMessage.fetchOne($0, key: "row-0")?.contentType } == "redacted")
    }

    @Test("A legacy label is not treated as a previously decrypted projection")
    func legacyCandidate() async throws {
        var row = TimelineWriteFixture.message(0)
        row.contentBody = "Не удалось расшифровать сообщение"
        let database = try TimelineWriteFixture.database(legacyMessages: [row])
        row.contentType = "unableToDecrypt"
        row.contentBody = "unavailable"
        try await write(row, database: database)
        #expect(try await database.read { try StoredMessage.fetchOne($0, key: "row-0")?.decryptionFailure } == .unavailable)
    }

    @Test("SDK trust failures cannot take the missing-key preservation path")
    func sdkCauses() {
        for cause in [UtdCause.verificationViolation, .unsignedDevice, .unknownDevice,
                      .withheldForUnverifiedOrInsecureDevice, .historicalMessageAndDeviceIsUnverified] {
            #expect(ChatDecryptionFailure(.megolmV1AesSha2(sessionId: "session", cause: cause)) == .trustRequirement)
        }
        #expect(ChatDecryptionFailure(.megolmV1AesSha2(sessionId: "session", cause: .unknown)) == .unavailable)
    }

    private func write(_ record: StoredMessage, database: AccountDatabase) async throws {
        try await Task.detached {
            try TimelineDiffBatcher.writeMappedEvents([TimelineWriteFixture.event(record)],
                roomId: TimelineWriteFixture.roomID, database: database, currentUserId: "",
                summary: .init(setCount: 1), historyRevision: TimelineHistoryRevision()) { _ in }
        }.value
    }
}
