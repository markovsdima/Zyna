//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Captures one account's database for the lifetime of an attachments screen.
/// SDK discovery and the chat share the catalog, never their timeline windows.
final class RoomPollCatalog: @unchecked Sendable {
    let roomId: String
    private let database: AccountDatabase
    private let onRoomChange: (String) -> Void
    #if DEBUG
    let diagnosticContext: String
    #endif

    init(roomId: String, database: AccountDatabase,
         onRoomChange: @escaping (String) -> Void = {
             PollStore.shared.roomDidUpdate.send(.init(roomId: $0, origin: .catalog))
         }) {
        self.roomId = roomId
        self.database = database
        self.onRoomChange = onRoomChange
        #if DEBUG
        diagnosticContext = "catalog=\(UUID().uuidString.prefix(8)) db=\(PollCacheDiagnostics.databaseKey(database.path)) room=\(PollCacheDiagnostics.key(roomId))"
        PollCacheDiagnostics.log("catalog-open \(diagnosticContext)")
        #endif
    }

    func page(limit: Int) async throws -> [RoomPollItem] {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        PollCacheDiagnostics.log("page-begin \(diagnosticContext) limit=\(limit)")
        #endif
        do {
            #if DEBUG
            try await DatabaseHandoffProbe.shared.beforeRead(database: database)
            let context = "\(diagnosticContext) origin=page"
            let read = try await database.read { [roomId] db in
                try PollCacheDiagnostics.read(context: context, requestedAt: began) {
                    try PollStore.fetchPolls(in: db, roomId: roomId, limit: limit)
                }
            }
            let items = read.value
            PollCacheDiagnostics.log("page-end \(diagnosticContext) totalMs=\(PollCacheDiagnostics.milliseconds(since: began)) deliveryMs=\(PollCacheDiagnostics.milliseconds(since: read.finished)) count=\(items.count)")
            #else
            let items = try await database.read { [roomId] db in
                try PollStore.fetchPolls(in: db, roomId: roomId, limit: limit)
            }
            #endif
            return items
        } catch {
            #if DEBUG
            PollCacheDiagnostics.log("page-error \(diagnosticContext) error=\(PollCacheDiagnostics.error(error))")
            #endif
            throw error
        }
    }

    func observe(limit: Int, onError: @escaping @MainActor @Sendable (Error) -> Void,
                 onChange: @escaping @MainActor @Sendable ([RoomPollItem]) -> Void) -> AnyDatabaseCancellable {
        #if DEBUG
        let context = "\(diagnosticContext) origin=observation observation=\(UUID().uuidString.prefix(8))"
        PollCacheDiagnostics.log("observe-begin \(context) limit=\(limit)")
        let observation = ValueObservation.tracking { [roomId] db in
            try PollCacheDiagnostics.read(context: context) {
                try PollStore.fetchPolls(in: db, roomId: roomId, limit: limit)
            }
        }.removeDuplicates()
        return database.observe(observation, on: .main,
                                   onError: { error in MainActor.assumeIsolated { onError(error) } }, onChange: { read in
            PollCacheDiagnostics.log("observe-deliver \(context) deliveryMs=\(PollCacheDiagnostics.milliseconds(since: read.finished)) count=\(read.value.count)")
            MainActor.assumeIsolated { onChange(read.value) }
        })
        #else
        let observation = ValueObservation.tracking { [roomId] db in
            try PollStore.fetchPolls(in: db, roomId: roomId, limit: limit)
        }.removeDuplicates()
        return database.observe(observation, on: .main,
                                   onError: { error in MainActor.assumeIsolated { onError(error) } },
                                   onChange: { items in MainActor.assumeIsolated { onChange(items) } })
        #endif
    }

    /// Called on the history source's serial queue. Positional removals and
    /// resets are window changes; only explicit redactions reach this method.
    func ingest(_ records: [(record: StoredMessage, isPollStart: Bool, senderProfile: PollSenderProfile)]) throws {
        guard !records.isEmpty else { return }
        try DatabaseWriteBatch.write(records, to: database, source: "poll-catalog", prepare: { db in
            let observer = PollCatalogChatChanges { [database, onRoomChange, roomId] in
                guard database.isActive else { return }
                onRoomChange(roomId)
            }
            db.add(transactionObserver: observer, extent: .nextTransaction)
        }, apply: { db, entry in
            var record = entry.record
            try PollStore.ingest(&record, isPollStart: entry.isPollStart, senderProfile: entry.senderProfile, in: db)
            // Do not insert partial chat rows or replace timeline identity.
            // Existing bubbles still receive changes observed by this source.
            if record.contentType == "poll" {
                try db.execute(sql: """
                    UPDATE storedMessage SET contentPollJSON = ?, contentBody = json_extract(?, '$.definition.question'),
                        isEdited = json_extract(?, '$.isEdited'), latestEditEventId = json_extract(?, '$.latestEditEventID')
                    WHERE roomId = ? AND eventId = ? AND contentType = 'poll'
                    AND contentPollJSON IS NOT ?
                    """, arguments: [record.contentPollJSON, record.contentPollJSON, record.contentPollJSON,
                                      record.contentPollJSON, roomId, record.eventId, record.contentPollJSON])
            } else if record.contentType == "redacted" {
                try db.execute(sql: """
                    UPDATE storedMessage SET contentType = 'redacted', contentBody = NULL, contentPollJSON = NULL
                    WHERE roomId = ? AND eventId = ? AND contentType = 'poll'
                    """, arguments: [roomId, record.eventId])
            }
        })
    }
}

/// Notify the chat once after a committed change to its rows or outgoing
/// state. Catalog-only discoveries and identical upserts need no refresh.
private final class PollCatalogChatChanges: TransactionObserver {
    private let onCommit: () -> Void
    private var changed = false

    init(onCommit: @escaping () -> Void) { self.onCommit = onCommit }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        switch eventKind.tableName {
        case "storedMessage", "pendingPollOperation", "pendingMediaGroup", "pendingMediaGroupItem": return true
        default: return false
        }
    }

    func databaseDidChange(with event: DatabaseEvent) {
        changed = true
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    func databaseDidCommit(_ db: Database) { if changed { onCommit() } }
    func databaseDidRollback(_ db: Database) {}
}
