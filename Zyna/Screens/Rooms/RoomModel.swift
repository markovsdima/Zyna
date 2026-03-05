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
    let avatarURL: URL?
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
            avatarURL: room.avatarURL.flatMap { Self.mxcToHTTPS($0) },
            avatarColor: Self.avatarColors[abs(room.id.hashValue) % Self.avatarColors.count],
            isOnline: false,
            unreadCount: Int(room.unreadCount),
            avatarInitials: String(initials.prefix(2))
        )
    }

    /// Converts `mxc://server_name/media_id` to Matrix media thumbnail URL.
    /// Uses the server_name from the mxc URI as the media host.
    private static func mxcToHTTPS(_ mxc: String) -> URL? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        let path = String(mxc.dropFirst(6)) // "server_name/media_id"
        guard let slashIndex = path.firstIndex(of: "/") else { return nil }
        let serverName = path[path.startIndex..<slashIndex]
        return URL(string: "https://\(serverName)/_matrix/media/v3/thumbnail/\(path)?width=96&height=96&method=crop")
    }
}
