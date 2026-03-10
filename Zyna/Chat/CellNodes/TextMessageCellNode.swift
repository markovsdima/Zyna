//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class TextMessageCellNode: MessageCellNode {

    // MARK: - Subnodes

    private let textNode = ASTextNode()

    // MARK: - Constants

    private static let bubbleInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

    // MARK: - Init

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        super.init(message: message, isGroupChat: isGroupChat)

        // Message text
        let bodyText: String
        switch message.content {
        case .text(let body):
            bodyText = body
        case .notice(let body):
            bodyText = body
        case .emote(let body):
            bodyText = "* \(message.senderDisplayName ?? "") \(body)"
        case .image:
            bodyText = "📷 Photo"
        case .voice:
            bodyText = "🎤 Voice message"
        case .unsupported(let typeName):
            bodyText = "[\(typeName)]"
        }

        textNode.attributedText = NSAttributedString(
            string: bodyText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: isOutgoing ? UIColor.white : UIColor.label
            ]
        )
        textNode.style.maxWidth = ASDimension(
            unit: .points,
            value: ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio - Self.bubbleInsets.left - Self.bubbleInsets.right - 50
        )

        // Bubble layout
        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            let timeSpec = ASStackLayoutSpec(
                direction: .vertical,
                spacing: 0,
                justifyContent: .end,
                alignItems: .end,
                children: [self.timeNode]
            )
            let textTimeRow = ASStackLayoutSpec(
                direction: .horizontal,
                spacing: 6,
                justifyContent: .start,
                alignItems: .end,
                children: [self.textNode, timeSpec]
            )
            return ASInsetLayoutSpec(insets: Self.bubbleInsets, child: textTimeRow)
        }
    }
}
