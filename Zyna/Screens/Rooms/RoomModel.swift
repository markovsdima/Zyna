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
    var isOnline: Bool
    var lastSeen: Date?
    let unreadCount: Int
    let avatarInitials: String
    let directUserId: String?
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
            timestamp: room.lastMessageTimestamp.map { Self.formatTimestamp($0) } ?? "",
            avatarURL: room.avatarURL.flatMap { Self.mxcToHTTPS($0) },
            avatarColor: Self.avatarColors[Self.stableHash(room.id) % Self.avatarColors.count],
            isOnline: false,
            lastSeen: nil,
            unreadCount: Int(room.unreadCount),
            avatarInitials: String(initials.prefix(2)),
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

    /// djb2 hash — stable across app launches, unlike `hashValue`.
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
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
