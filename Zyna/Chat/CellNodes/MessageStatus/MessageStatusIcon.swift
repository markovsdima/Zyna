//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Visual state of the status indicator shown next to a message
/// timestamp. Independent of the storage-level `sendStatus` string.
enum MessageStatusIcon: Equatable {

    /// Not yet confirmed by the server. Rendered as a rotating clock.
    case pending

    /// Server acknowledged receipt (one checkmark).
    case sent

    /// Sync echoed the event back and it is considered delivered
    /// (two overlapping checkmarks).
    case delivered

    /// Terminal failure. Red circle with a white exclamation mark.
    case failed

    /// Maps the storage-level `sendStatus` raw string to a visual
    /// state. Returns nil when no indicator should be shown
    /// (e.g. historical / other-user messages).
    static func from(sendStatus: String) -> MessageStatusIcon? {
        switch sendStatus {
        case "queued", "sending", "retrying":
            return .pending
        case "sent":
            return .sent
        case "synced":
            return .delivered
        case "failed":
            return .failed
        default:
            return nil
        }
    }
}
