//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum LastSeenStyle {
    /// Chat title bar, contacts list — relative time ("5 min ago", "3h ago")
    case chat
    /// Profile screen — exact time ("today at 14:30")
    case expanded
}

extension Date {

    func presenceLastSeenString(style: LastSeenStyle = .chat) -> String {
        let now = Date()
        let diff = now.timeIntervalSince(self)
        let calendar = Calendar.current

        // Just now — both styles
        if diff < 60 {
            return String(localized: "last seen just now")
        }

        // Chat: relative minutes
        if style == .chat && diff < 3600 {
            let minutes = Int(diff / 60)
            return String(localized: "last seen \(minutes) minutes ago")
        }

        // Calendar day comparison for today/yesterday boundary
        let selfDay = calendar.startOfDay(for: self)
        let todayStart = calendar.startOfDay(for: now)
        let dayDiff = calendar.dateComponents([.day], from: selfDay, to: todayStart).day ?? 0

        let timeString = self.shortTimeString

        switch dayDiff {
        case 0:
            // Today
            if style == .chat {
                let hours = Int(diff / 3600)
                return String(localized: "last seen \(hours) hours ago")
            } else {
                return String(localized: "last seen today at \(timeString)")
            }

        case 1:
            // Yesterday
            return String(localized: "last seen yesterday at \(timeString)")

        default:
            // Older
            let dateString: String
            if calendar.component(.year, from: self) == calendar.component(.year, from: now) {
                dateString = self.shortDateString
            } else {
                dateString = self.shortDateWithYearString
            }
            return String(localized: "last seen \(dateString)")
        }
    }

    // MARK: - Formatters

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let shortDateWithYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd y")
        return f
    }()

    private var shortTimeString: String {
        Date.shortTimeFormatter.string(from: self)
    }

    private var shortDateString: String {
        Date.shortDateFormatter.string(from: self)
    }

    private var shortDateWithYearString: String {
        Date.shortDateWithYearFormatter.string(from: self)
    }
}
