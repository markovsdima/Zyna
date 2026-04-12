//
//  RoomModel.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 05.03.2026.
//

import UIKit

struct RoomModel: Equatable {
    let id: String
    let name: String
    let lastMessage: String
    let timestamp: String
    let avatar: AvatarViewModel
    var isOnline: Bool
    var lastSeen: Date?
    let unreadCount: Int
    let directUserId: String?
}

extension RoomModel {

    init(from room: RoomSummary) {
        let avatarId = room.directUserId ?? room.id
        let avatar = AvatarViewModel(
            userId: avatarId,
            displayName: room.displayName,
            mxcAvatarURL: room.avatarURL
        )
        self.init(
            id: room.id,
            name: room.displayName,
            lastMessage: room.lastMessage ?? "",
            timestamp: room.lastMessageTimestamp.map { Self.formatTimestamp($0) } ?? "",
            avatar: avatar,
            isOnline: false,
            lastSeen: nil,
            unreadCount: Int(room.unreadCount),
            directUserId: room.directUserId
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return dateFormatter.string(from: date)
        }
    }
}
