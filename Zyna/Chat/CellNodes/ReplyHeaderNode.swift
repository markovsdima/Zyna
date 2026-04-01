//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Compact reply header shown inside a message bubble.
/// Tap handling is done by the parent ContextSourceNode via onQuickTap.
final class ReplyHeaderNode: ASDisplayNode {

    private let barNode = ASDisplayNode()
    private let nameNode = ASTextNode()
    private let bodyNode = ASTextNode()

    init(replyInfo: ReplyInfo, isOutgoing: Bool) {
        super.init()
        automaticallyManagesSubnodes = true

        barNode.backgroundColor = isOutgoing ? UIColor.white.withAlphaComponent(0.6) : .systemBlue
        barNode.cornerRadius = 1
        barNode.style.width = ASDimension(unit: .points, value: 2)
        barNode.style.minHeight = ASDimension(unit: .points, value: 16)
        barNode.isLayerBacked = true

        let maxTextWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio - 40

        let senderText = replyInfo.senderDisplayName ?? replyInfo.senderId
        nameNode.maximumNumberOfLines = 1
        nameNode.truncationMode = .byTruncatingTail
        nameNode.isLayerBacked = true
        nameNode.style.maxWidth = ASDimension(unit: .points, value: maxTextWidth)
        nameNode.attributedText = NSAttributedString(
            string: senderText.isEmpty ? "Unknown" : senderText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: isOutgoing ? UIColor.white.withAlphaComponent(0.9) : UIColor.systemBlue
            ]
        )

        let bodyText = replyInfo.body
        bodyNode.maximumNumberOfLines = 1
        bodyNode.truncationMode = .byTruncatingTail
        bodyNode.isLayerBacked = true
        bodyNode.style.maxWidth = ASDimension(unit: .points, value: maxTextWidth)
        bodyNode.attributedText = NSAttributedString(
            string: bodyText.isEmpty ? "Message" : bodyText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: isOutgoing
                    ? UIColor.white.withAlphaComponent(0.7)
                    : UIColor.secondaryLabel
            ]
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let textColumn = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 1,
            justifyContent: .start,
            alignItems: .stretch,
            children: [nameNode, bodyNode]
        )
        textColumn.style.flexShrink = 1
        textColumn.style.flexGrow = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 6,
            justifyContent: .start,
            alignItems: .stretch,
            children: [barNode, textColumn]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0),
            child: row
        )
    }
}
