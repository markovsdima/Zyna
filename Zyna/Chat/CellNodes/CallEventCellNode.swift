//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Centered system cell for call events
/// (e.g. "Call", "Call ended", "Missed call").
final class CallEventCellNode: SystemEventCellNode {

    init(message: ChatMessage) {
        super.init()

        let text: String
        let icon: String

        if case .callEvent(let type, _, let reason) = message.content {
            text = type.displayText(reason: reason)
            icon = (reason == "timeout" || reason == "declined")
                ? "phone.arrow.down.left" : "phone"
        } else {
            icon = "phone"
            text = "Call"
        }

        let timeString = MessageCellHelpers.timeFormatter.string(from: message.timestamp)
        let direction = message.isOutgoing ? "Outgoing" : "Incoming"

        let attachment = NSTextAttachment()
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        attachment.image = UIImage(systemName: icon, withConfiguration: iconConfig)?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(
            string: " \(direction) · \(text) · \(timeString)",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        ))

        labelNode.attributedText = result
    }
}
