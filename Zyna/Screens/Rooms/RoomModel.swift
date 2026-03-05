//
//  RoomModel.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 05.03.2026.
//

import UIKit

struct RoomModel {
    let id: String
    let name: String
    let lastMessage: String
    let timestamp: String
    let avatarColor: UIColor
    let isOnline: Bool
    let unreadCount: Int
    let avatarInitials: String
}

extension RoomModel {
    private static let avatarColors: [UIColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemRed,
        .systemPurple, .systemTeal, .systemIndigo, .systemPink
    ]

    init(from room: RoomSummary) {
        let initials = room.displayName
            .split(separator: " ")
            .compactMap { $0.first }
            .map(String.init)
            .joined()

        self.init(
            id: room.id,
            name: room.displayName,
            lastMessage: room.lastMessage ?? "",
            timestamp: "",
            avatarColor: Self.avatarColors[abs(room.id.hashValue) % Self.avatarColors.count],
            isOnline: false,
            unreadCount: Int(room.unreadCount),
            avatarInitials: String(initials.prefix(2))
        )
    }
}
