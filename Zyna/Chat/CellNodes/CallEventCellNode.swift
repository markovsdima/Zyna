//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Centered system-message style cell for call events
/// (e.g. "Call", "Call ended", "Missed call").
final class CallEventCellNode: ASCellNode {

    private let labelNode = ASTextNode()

    init(message: ChatMessage) {
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none

        let text: String
        let icon: String

        if case .callEvent(let type, _, let reason) = message.content {
            let displayText = type.displayText(reason: reason)
            icon = (reason == "timeout" || reason == "declined") ? "phone.arrow.down.left" : "phone"
            text = displayText
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let centered = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: .minimumXY,
            child: labelNode
        )
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16),
            child: centered
        )
    }
}
