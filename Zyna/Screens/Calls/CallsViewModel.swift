//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import GRDB

private let logCalls = ScopedLog(.ui)

final class CallsViewModel {

    @Published private(set) var calls: [CallHistoryModel] = []

    var onCallTapped: ((String) -> Void)?

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseService.shared.dbQueue) {
        self.dbQueue = dbQueue
        loadCalls()
    }

    func reload() {
        loadCalls()
    }

    func call(at index: Int) {
        guard index < calls.count else { return }
        onCallTapped?(calls[index].roomId)
    }

    private func loadCalls() {
        let results: [CallHistoryModel] = (try? dbQueue.read { db in
            let rows = try StoredMessage
                .filter(Column("contentType") == "call")
                .order(Column("timestamp").desc)
                .limit(200)
                .fetchAll(db)

            logCalls("Call history query: \(rows.count) rows found")

            let roomIds = Set(rows.map(\.roomId))
            var roomMap: [String: StoredRoom] = [:]
            for roomId in roomIds {
                if let room = try StoredRoom.fetchOne(db, key: roomId) {
                    roomMap[roomId] = room
                }
            }

            return rows.compactMap { msg -> CallHistoryModel? in
                guard let typeRaw = msg.contentCaption,
                      let type = CallEventType(rawValue: typeRaw) else { return nil }

                let room = roomMap[msg.roomId]
                let roomName = room?.displayName ?? "Unknown"
                let avatarId = room?.directUserId ?? msg.roomId
                let avatar = AvatarViewModel(
                    userId: avatarId,
                    displayName: roomName,
                    mxcAvatarURL: room?.avatarURL
                )

                return CallHistoryModel(
                    callId: msg.contentBody ?? msg.id,
                    roomId: msg.roomId,
                    roomName: roomName,
                    avatar: avatar,
                    isOutgoing: msg.isOutgoing,
                    type: type,
                    reason: msg.contentMimetype,
                    timestamp: Date(timeIntervalSince1970: msg.timestamp)
                )
            }
        }) ?? []

        calls = results
    }
}
