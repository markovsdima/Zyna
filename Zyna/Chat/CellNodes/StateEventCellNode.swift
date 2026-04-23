//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Centered system cell for Matrix room/membership/profile events.
final class StateEventCellNode: SystemEventCellNode {

    init(message: ChatMessage) {
        super.init()

        let text: String
        if case .systemEvent(let value, _) = message.content {
            text = value
        } else {
            text = String(localized: "Room event")
        }

        labelNode.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }
}
