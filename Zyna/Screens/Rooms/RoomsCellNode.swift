//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

class RoomsCellNode: ASCellNode {

    private let chat: RoomModel
    private let avatarNode = ASDisplayNode()
    private let avatarTextNode = ASTextNode()
    private let nameNode = ASTextNode()
    private let messageNode = ASTextNode()
    private let timestampNode = ASTextNode()
    private let onlineIndicatorNode = ASDisplayNode()
    private let unreadBadgeNode = ASDisplayNode()
    private let unreadCountNode = ASTextNode()
    private let separatorNode = ASDisplayNode()

    init(chat: RoomModel) {
        self.chat = chat
        super.init()

        automaticallyManagesSubnodes = true
        setupNodes()
    }

    private func setupNodes() {
        // Avatar
        avatarNode.backgroundColor = chat.avatarColor
        avatarNode.cornerRadius = 25
        avatarNode.borderWidth = 0.5
        avatarNode.borderColor = UIColor.separator.cgColor

        // Avatar initials
        avatarTextNode.attributedText = NSAttributedString(
            string: chat.avatarInitials,
            attributes: [
                .font: UIFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: UIColor.white
            ]
        )

        // Name
        nameNode.attributedText = NSAttributedString(
            string: chat.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        nameNode.maximumNumberOfLines = 1
        nameNode.truncationMode = .byTruncatingTail

        // Message
        messageNode.attributedText = NSAttributedString(
            string: chat.lastMessage,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        messageNode.maximumNumberOfLines = 2
        messageNode.truncationMode = .byTruncatingTail

        // Timestamp
        timestampNode.attributedText = NSAttributedString(
            string: chat.timestamp,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.tertiaryLabel
            ]
        )
        timestampNode.maximumNumberOfLines = 1

        // Online indicator
        onlineIndicatorNode.backgroundColor = UIColor.systemGreen
        onlineIndicatorNode.cornerRadius = 6
        onlineIndicatorNode.borderWidth = 2
        onlineIndicatorNode.borderColor = UIColor.systemBackground.cgColor

        // Unread badge
        unreadBadgeNode.backgroundColor = UIColor.systemBlue
        unreadBadgeNode.cornerRadius = 10

        unreadCountNode.attributedText = NSAttributedString(
            string: "\(chat.unreadCount)",
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.white
            ]
        )

        // Separator
        separatorNode.backgroundColor = UIColor.separator
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Avatar: circle with centered initials
        avatarNode.style.preferredSize = CGSize(width: 50, height: 50)
        let avatarInitials = ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: .minimumXY, child: avatarTextNode)
        let avatar = ASOverlayLayoutSpec(child: avatarNode, overlay: avatarInitials)

        // Avatar with optional online indicator
        let avatarSection: ASLayoutSpec
        if chat.isOnline {
            onlineIndicatorNode.style.preferredSize = CGSize(width: 12, height: 12)
            onlineIndicatorNode.style.layoutPosition = CGPoint(x: 38, y: 38)
            avatarSection = ASAbsoluteLayoutSpec(children: [avatar, onlineIndicatorNode])
            avatarSection.style.preferredSize = CGSize(width: 50, height: 50)
        } else {
            avatarSection = ASWrapperLayoutSpec(layoutElement: avatar)
        }

        // Right side: timestamp + optional unread badge
        var rightElements: [ASLayoutElement] = [timestampNode]

        if chat.unreadCount > 0 {
            unreadBadgeNode.style.preferredSize = CGSize(width: 20, height: 20)
            let badgeCenter = ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: .minimumXY, child: unreadCountNode)
            let badge = ASOverlayLayoutSpec(child: unreadBadgeNode, overlay: badgeCenter)
            rightElements.append(badge)
        }

        let rightStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 4,
            justifyContent: .start,
            alignItems: .end,
            children: rightElements
        )

        // Text: name + message
        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .start,
            alignItems: .start,
            children: [nameNode, messageNode]
        )
        textStack.style.flexShrink = 1
        textStack.style.flexGrow = 1

        // Main row: avatar + text + right
        let mainContent = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .start,
            children: [avatarSection, textStack, rightStack]
        )

        let contentInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16),
            child: mainContent
        )

        // Separator at the bottom, full width
        separatorNode.style.preferredSize = CGSize(width: constrainedSize.max.width, height: 0.5)

        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [contentInset, separatorNode]
        )
    }

    override func didLoad() {
        super.didLoad()
        backgroundColor = UIColor.systemBackground

        let highlightedBackground = UIView()
        highlightedBackground.backgroundColor = UIColor.systemGray6
        selectedBackgroundView = highlightedBackground
    }
}
