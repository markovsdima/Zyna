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
        reload()
    }

    func reload() {
        Task.detached { [weak self] in
            self?.loadCalls()
        }
    }

    func call(at index: Int) {
        guard index < calls.count else { return }
        onCallTapped?(calls[index].roomId)
    }

    private func loadCalls() {
        let currentUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        let results: [CallHistoryModel] = (try? dbQueue.write { db in
            try StoredMatrixRTCCall.refreshRecentCallProjections(
                limit: 200,
                currentUserId: currentUserId,
                in: db
            )

            let rows = try StoredMatrixRTCCall
                .order(Column("timestamp").desc)
                .limit(200)
                .fetchAll(db)

            logCalls("MatrixRTC call history query: \(rows.count) rows found")

            let roomIds = Set(rows.map(\.roomId))
            var roomMap: [String: StoredRoom] = [:]
            for roomId in roomIds {
                if let room = try StoredRoom.fetchOne(db, key: roomId) {
                    roomMap[roomId] = room
                }
            }

            return rows.compactMap { msg -> CallHistoryModel? in
                let room = roomMap[msg.roomId]
                let roomName = room?.displayName ?? "Unknown"
                let avatarId = room?.directUserId ?? msg.roomId
                let avatar = AvatarViewModel(
                    userId: avatarId,
                    displayName: roomName,
                    mxcAvatarURL: room?.avatarURL
                )

                return CallHistoryModel(
                    callId: msg.notificationEventId,
                    roomId: msg.roomId,
                    roomName: roomName,
                    avatar: avatar,
                    isOutgoing: msg.isOutgoing,
                    isVoiceCall: msg.isVoiceCall,
                    outcome: msg.historyOutcome,
                    timestamp: Date(timeIntervalSince1970: msg.timestamp)
                )
            }
        }) ?? []

        DispatchQueue.main.async { [weak self] in
            guard let self, self.calls != results else { return }
            self.calls = results
        }
    }
}
