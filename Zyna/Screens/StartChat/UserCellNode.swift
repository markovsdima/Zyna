//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class UserCellNode: ASCellNode {

    private let avatarNode = ASDisplayNode()
    private let initialsNode = ASTextNode()
    private let nameNode = ASTextNode()
    private let userIdNode = ASTextNode()
    private let checkmarkNode = ASImageNode()
    private let separatorNode = ASDisplayNode()

    private let showCheckmark: Bool

    init(user: UserProfile, isSelected: Bool = false, showCheckmark: Bool = false) {
        self.showCheckmark = showCheckmark
        super.init()
        automaticallyManagesSubnodes = true

        let displayName = user.displayName ?? user.userId
        let initials = String(displayName.prefix(1)).uppercased()

        avatarNode.backgroundColor = .systemGray4
        avatarNode.cornerRadius = 22
        avatarNode.style.preferredSize = CGSize(width: 44, height: 44)

        initialsNode.attributedText = NSAttributedString(
            string: initials,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: UIColor.white
            ]
        )

        nameNode.attributedText = NSAttributedString(
            string: displayName,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: UIColor.label
            ]
        )
        nameNode.maximumNumberOfLines = 1
        nameNode.truncationMode = .byTruncatingTail

        userIdNode.attributedText = NSAttributedString(
            string: user.userId,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        userIdNode.maximumNumberOfLines = 1
        userIdNode.truncationMode = .byTruncatingTail

        if showCheckmark {
            let imageName = isSelected ? "checkmark.circle.fill" : "circle"
            let color: UIColor = isSelected ? .systemBlue : .systemGray3
            checkmarkNode.image = UIImage(systemName: imageName)?.withTintColor(color, renderingMode: .alwaysOriginal)
            checkmarkNode.style.preferredSize = CGSize(width: 24, height: 24)
        }

        separatorNode.backgroundColor = .separator
        separatorNode.style.height = ASDimension(unit: .points, value: 0.5)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let avatarWithInitials = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: .minimumXY,
            child: initialsNode
        )
        let avatar = ASBackgroundLayoutSpec(child: avatarWithInitials, background: avatarNode)
        avatar.style.preferredSize = CGSize(width: 44, height: 44)

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .center,
            alignItems: .start,
            children: [nameNode, userIdNode]
        )
        textStack.style.flexShrink = 1
        textStack.style.flexGrow = 1

        var rowChildren: [ASLayoutElement] = [avatar, textStack]
        if showCheckmark {
            rowChildren.append(checkmarkNode)
        }

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: rowChildren
        )

        let padded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16),
            child: row
        )

        let withSeparator = ASStackLayoutSpec.vertical()
        withSeparator.children = [padded, separatorNode]
        return withSeparator
    }
}
