//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

struct CallHistoryModel: Equatable {
    let callId: String
    let roomId: String
    let roomName: String
    let avatar: AvatarViewModel
    let isOutgoing: Bool
    let isVoiceCall: Bool
    let outcome: MatrixRTCCallHistoryOutcome
    let timestamp: Date

    var isNegativeOutcome: Bool {
        outcome.isNegative
    }

    var statusText: String {
        let direction = isOutgoing ? String(localized: "Outgoing") : String(localized: "Incoming")
        return "\(direction) · \(outcome.displayText)"
    }

    var formattedTime: String {
        Self.formatTimestamp(timestamp)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func formatTimestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return dateFormatter.string(from: date)
        }
    }
}
