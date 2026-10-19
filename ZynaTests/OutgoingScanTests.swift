//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
@testable import Zyna

@Suite("Outgoing cache scans")
struct OutgoingScanTests {
    @Test("Voice scans release main while fetching and keep candidate filtering")
    @MainActor
    func voiceReadsOffMain() async throws {
        let database = try Fixture.database()
        try await database.write { db in
            try Fixture.insert("missing", in: db)
            try Fixture.insert("ready", asset: true, in: db)
            try Fixture.insert("sent", state: .sent, eventID: "$sent", in: db)
            try Fixture.insert("failed", state: .failed, in: db)
        }
        let readsOnMain = Atomic<[Bool]>([])
        let firstRead = Atomic(false)
        let mainProgressed = Atomic(false)
        let didRelease = Atomic(false)
        let gate = DispatchSemaphore(value: 0)
        try await database.write { db in
            db.trace(options: .statement) { event in
                guard case .statement(let statement) = event,
                      statement.sql.hasPrefix("SELECT"),
                      statement.sql.contains("pendingMediaGroup") else { return }
                readsOnMain.modify { $0.append(Thread.isMainThread) }
                // A deliberately held read must still allow a main-actor
                // task to run. Skip the wait if a regression runs on main.
                guard firstRead.tryToSetFlag(), !Thread.isMainThread else { return }
                Task { @MainActor in
                    mainProgressed.wrappedValue = true
                    gate.signal()
                }
                didRelease.wrappedValue = gate.wait(timeout: .now() + 5) == .success
            }
        }
        let voices = PendingDirectVoiceService(database: database)
        let ready = await voices.outboxCandidates()
        let missing = await voices.missingRecordCandidates()
        #expect(ready.map(\.envelope.id) == ["ready"])
        #expect(missing.map(\.envelope.id) == ["missing"])
        #expect(!readsOnMain.wrappedValue.isEmpty)
        #expect(readsOnMain.wrappedValue.allSatisfy { !$0 })
        #expect(mainProgressed.wrappedValue && didRelease.wrappedValue)
        #expect(await voices.outboxCandidates(envelopeIds: []).isEmpty)
        #expect(await voices.missingRecordCandidates(envelopeIds: ["ready"]).isEmpty)
    }

    @Test("An asset prepared after a scan prevents failure, for every media outbox",
          arguments: [OutgoingEnvelopeService.MissingAsset.image, .video, .voice, .file, .forwardedMedia])
    func assetArrivesAfterScan(asset: OutgoingEnvelopeService.MissingAsset) async throws {
        let database = try Fixture.database()
        try await database.write { try Fixture.insert("late", in: $0) }
        let scanned = try #require(await PendingDirectVoiceService(database: database).missingRecordCandidates().first)
        try await database.write { db in
            // Only existence by itemId matters to the failure guard.
            try db.execute(sql: "INSERT INTO \(asset.rawValue) (itemId) VALUES (?)", arguments: [scanned.item.id])
        }
        let envelopes = OutgoingEnvelopeService(database: database)
        #expect(!envelopes.markMissingAssetFailed(item: scanned.item, asset: asset))
        let state = try await database.read { db in
            try OutgoingEnvelopeItemRecord.fetchOne(db, key: scanned.item.id)?.decodedTransportState
        }
        #expect(state == .queued)
    }

    enum SubsequentChange: CaseIterable { case transaction, binding, sending, echo, none }

    @Test("A missing-asset failure applies only to the unchanged queued attempt",
          arguments: SubsequentChange.allCases)
    func staleAttempt(change: SubsequentChange) async throws {
        let database = try Fixture.database()
        try await database.write { try Fixture.insert("attempt", in: $0) }
        let scanned = try #require(await PendingDirectVoiceService(database: database).missingRecordCandidates().first)
        try await database.write { db in
            var item = try #require(try OutgoingEnvelopeItemRecord.fetchOne(db, key: scanned.item.id))
            switch change {
            case .transaction: item.transactionId = "new-transaction"
            case .binding: item.bindingToken = "new-binding"
            case .sending: item.transportState = OutgoingTransportState.sending.rawValue
            case .echo: item.eventId = "$accepted"
            case .none: break
            }
            try item.save(db)
        }
        let envelopes = OutgoingEnvelopeService(database: database)
        let failed = envelopes.markMissingAssetFailed(item: scanned.item, asset: .voice)
        #expect(failed == (change == .none))
        let states = try await database.read { db in
            (try OutgoingEnvelopeItemRecord.fetchOne(db, key: scanned.item.id)?.decodedTransportState,
             try OutgoingEnvelopeRecord.fetchOne(db, key: scanned.envelope.id)?.decodedState)
        }
        if change == .none {
            #expect(states.0 == .failed && states.1 == .failed)
        } else {
            #expect(states.0 != .failed && states.1 != .failed)
        }
    }

    private enum Fixture {
        static func envelope(_ id: String, state: OutgoingTransportState = .queued) -> OutgoingEnvelopeRecord {
            .init(id: id, roomId: "!room:example.org", caption: nil, captionPlacement: "bottom",
                  expectedItemCount: 1, createdAt: 1, replyEventId: nil, replySenderId: nil,
                  replySenderName: nil, replyBody: nil, kind: "voice", state: state.rawValue,
                  payloadJSON: OutgoingEnvelopePayload.voice(.init(duration: 1, waveform: [], localFileName: "voice.m4a")).encodeJSON(),
                  zynaAttributesJSON: nil, matrixSessionId: "session")
        }

        static func item(_ id: String, state: OutgoingTransportState = .queued, eventID: String? = nil) -> OutgoingEnvelopeItemRecord {
            .init(id: "\(id):0", groupId: id, itemIndex: 0, bindingToken: nil,
                  transactionId: "tx-\(id)", eventId: eventID, mediaSourceJSON: nil,
                  previewImageData: nil, previewWidth: nil, previewHeight: nil,
                  transportState: state.rawValue)
        }

        static func voice(_ id: String) -> PendingDirectVoiceRecord {
            .init(itemId: "\(id):0", envelopeId: id, roomId: "!room:example.org", mimetype: "audio/mp4",
                  uploadedVoiceJSON: nil, createdAt: 1, updatedAt: 1)
        }

        static func database() throws -> AccountDatabase {
            let database = AccountDatabase(try DatabaseQueue())
            try database.write { db in
                func table<T>(_ name: String, sample: T, key: String) throws {
                    let columns = Mirror(reflecting: sample).children.compactMap(\.label)
                    let definitions = columns.map { $0 == key ? "\"\($0)\" TEXT PRIMARY KEY" : "\"\($0)\"" }
                    try db.execute(sql: "CREATE TABLE \(name) (\(definitions.joined(separator: ",")))")
                }
                try table("pendingMediaGroup", sample: envelope("sample"), key: "id")
                try table("pendingMediaGroupItem", sample: item("sample"), key: "id")
                try table("pendingDirectVoice", sample: voice("sample"), key: "itemId")
                for asset in [OutgoingEnvelopeService.MissingAsset.image, .video, .file, .forwardedMedia] {
                    try db.execute(sql: "CREATE TABLE \(asset.rawValue) (itemId TEXT PRIMARY KEY)")
                }
            }
            return database
        }

        static func insert(_ id: String, state: OutgoingTransportState = .queued,
                           eventID: String? = nil, asset: Bool = false, in db: Database) throws {
            try envelope(id, state: state).insert(db)
            try item(id, state: state, eventID: eventID).insert(db)
            if asset { try voice(id).insert(db) }
        }
    }
}
