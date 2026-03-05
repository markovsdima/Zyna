//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class TextMessageCellNode: ASCellNode {

    // MARK: - Subnodes

    private let bubbleNode = ASDisplayNode()
    private let textNode = ASTextNode()
    private let timeNode = ASTextNode()
    private let senderNameNode = ASTextNode()

    // MARK: - State

    private let isOutgoing: Bool
    private let showSenderName: Bool

    // MARK: - Constants

    private static let maxBubbleWidthRatio: CGFloat = 0.75
    private static let bubbleInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
    private static let cellInsets = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let senderColors: [UIColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange,
        .systemPurple, .systemTeal, .systemIndigo, .systemPink
    ]

    // MARK: - Init

    init(message: ChatMessage, isGroupChat: Bool = false) {
        self.isOutgoing = message.isOutgoing
        self.showSenderName = !message.isOutgoing && isGroupChat
        super.init()

        automaticallyManagesSubnodes = true
        selectionStyle = .none

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
            value: ScreenConstants.width * Self.maxBubbleWidthRatio - Self.bubbleInsets.left - Self.bubbleInsets.right - 50
        )

        // Timestamp
        timeNode.attributedText = NSAttributedString(
            string: Self.timeFormatter.string(from: message.timestamp),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: isOutgoing
                    ? UIColor.white.withAlphaComponent(0.7)
                    : UIColor.secondaryLabel
            ]
        )

        // Bubble
        bubbleNode.backgroundColor = isOutgoing ? .systemBlue : .systemGray5
        bubbleNode.cornerRadius = 18
        bubbleNode.clipsToBounds = true

        // Sender name
        if showSenderName, let name = message.senderDisplayName {
            let colorIndex = Self.stableHash(message.senderId) % Self.senderColors.count
            senderNameNode.attributedText = NSAttributedString(
                string: name,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: Self.senderColors[colorIndex]
                ]
            )
        }
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Time aligned to bottom
        let timeSpec = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .end,
            alignItems: .end,
            children: [timeNode]
        )

        // Text + time row
        let textTimeRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 6,
            justifyContent: .start,
            alignItems: .end,
            children: [textNode, timeSpec]
        )

        let paddedContent = ASInsetLayoutSpec(
            insets: Self.bubbleInsets,
            child: textTimeRow
        )

        let bubble = ASBackgroundLayoutSpec(child: paddedContent, background: bubbleNode)

        // Sender name above bubble (for incoming in group chats)
        let bubbleWithName: ASLayoutElement
        if showSenderName {
            let nameInset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 0, left: 12, bottom: 2, right: 0),
                child: senderNameNode
            )
            bubbleWithName = ASStackLayoutSpec(
                direction: .vertical,
                spacing: 0,
                justifyContent: .start,
                alignItems: .start,
                children: [nameInset, bubble]
            )
        } else {
            bubbleWithName = bubble
        }

        // Spacer for left/right alignment
        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let hStack = ASStackLayoutSpec.horizontal()
        hStack.spacing = 4
        hStack.alignItems = .start
        hStack.children = isOutgoing
            ? [spacer, bubbleWithName]
            : [bubbleWithName, spacer]

        return ASInsetLayoutSpec(insets: Self.cellInsets, child: hStack)
    }

    // MARK: - Helpers

    /// djb2 hash — stable across app launches, unlike `hashValue`.
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }
}
