//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Centered system cell for MatrixRTC call notification events.
final class MatrixRTCCallEventCellNode: SystemEventCellNode {

    init(message: ChatMessage, isDirect: Bool, currentUserId: String?) {
        super.init()

        let text: String
        let icon: String
        if case .matrixRTCCall(let details) = message.content {
            text = details.timelineText(isDirect: isDirect, currentUserId: currentUserId)
            let negativeOutcome = details.historyOutcome?.isNegative
                ?? (isDirect && !details.declinedBy.isEmpty)
            if details.isVoiceCall {
                icon = negativeOutcome ? "phone.down" : "phone"
            } else {
                icon = negativeOutcome ? "video.slash" : "video"
            }
        } else {
            text = String(localized: "Call started")
            icon = "phone"
        }

        let timeString = MessageCellHelpers.timeFormatter.string(from: message.timestamp)

        let attachment = NSTextAttachment()
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        attachment.image = UIImage(systemName: icon, withConfiguration: iconConfig)?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(
            string: " \(text) · \(timeString)",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        ))

        labelNode.attributedText = result
    }
}
