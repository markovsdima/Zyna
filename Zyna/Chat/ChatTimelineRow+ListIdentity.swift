//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

extension ChatTimelineRow {
    var listIdentifier: String {
        switch self {
        case .dateDivider(let date): return "date:" + date.id
        case .message(let message):
            if let group = message.mediaGroupPresentation {
                if group.rendersCompositeBubble { return "group:" + group.id }
                if group.hidesStandaloneBubble, let media = message.zynaAttributes.mediaGroup {
                    return "group:\(group.id):hidden:\(media.index)"
                }
            }
            return "message:" + (message.eventId ?? message.transactionId ?? message.id)
        }
    }
}
