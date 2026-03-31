//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Observes all messages for a room in GRDB via ValueObservation.
/// Delivers (new, previous) on the main queue after each committed transaction.
final class RoomMessageObserver {

    private let roomId: String
    private let dbQueue: DatabaseQueue
    private var cancellable: AnyDatabaseCancellable?
    private var previousMessages: [StoredMessage]?

    /// Fired on main queue with (newMessages, previousMessages).
    /// `previous` is nil on first fire.
    var onChange: ((_ new: [StoredMessage], _ previous: [StoredMessage]?) -> Void)?

    init(roomId: String, dbQueue: DatabaseQueue) {
        self.roomId = roomId
        self.dbQueue = dbQueue
    }

    func start() {
        let roomId = self.roomId
        let observation = ValueObservation.tracking { db in
            try StoredMessage
                .filter(Column("roomId") == roomId)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }

        cancellable = observation.start(in: dbQueue, scheduling: .async(onQueue: .main), onError: { error in
            ScopedLog(.database)("Observation error: \(error)")
        }, onChange: { [weak self] messages in
            guard let self else { return }
            let prev = self.previousMessages
            self.previousMessages = messages
            self.onChange?(messages, prev)
        })
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
