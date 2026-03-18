//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class CreateGroupNode: BaseNode {

    let nameInputNode = ASEditableTextNode()
    let topicInputNode = ASEditableTextNode()
    let membersLabel = ASTextNode()
    let membersCountNode = ASTextNode()
    let createButtonNode = ASButtonNode()

    private let nameLabel = ASTextNode()
    private let topicLabel = ASTextNode()
    private let nameSeparator = ASDisplayNode()
    private let topicSeparator = ASDisplayNode()

    override init() {
        super.init()

        nameLabel.attributedText = NSAttributedString(
            string: "Group Name",
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )

        nameInputNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16)
        ]
        nameInputNode.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        nameInputNode.style.minHeight = ASDimension(unit: .points, value: 36)

        nameSeparator.backgroundColor = .separator
        nameSeparator.style.height = ASDimension(unit: .points, value: 0.5)

        topicLabel.attributedText = NSAttributedString(
            string: "Topic (optional)",
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )

        topicInputNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16)
        ]
        topicInputNode.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        topicInputNode.style.minHeight = ASDimension(unit: .points, value: 36)

        topicSeparator.backgroundColor = .separator
        topicSeparator.style.height = ASDimension(unit: .points, value: 0.5)

        membersLabel.attributedText = NSAttributedString(
            string: "Members",
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )

        createButtonNode.setTitle("Create Group", with: UIFont.systemFont(ofSize: 17, weight: .semibold), with: .white, for: .normal)
        createButtonNode.backgroundColor = .systemBlue
        createButtonNode.cornerRadius = 12
        createButtonNode.style.height = ASDimension(unit: .points, value: 50)
    }

    func updateMembersCount(_ count: Int) {
        membersCountNode.attributedText = NSAttributedString(
            string: "\(count) member\(count == 1 ? "" : "s")",
            attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.label]
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let nameSection = ASStackLayoutSpec(
            direction: .vertical, spacing: 4, justifyContent: .start, alignItems: .stretch,
            children: [nameLabel, nameInputNode, nameSeparator]
        )

        let topicSection = ASStackLayoutSpec(
            direction: .vertical, spacing: 4, justifyContent: .start, alignItems: .stretch,
            children: [topicLabel, topicInputNode, topicSeparator]
        )

        let membersSection = ASStackLayoutSpec(
            direction: .vertical, spacing: 4, justifyContent: .start, alignItems: .stretch,
            children: [membersLabel, membersCountNode]
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let mainStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 24, justifyContent: .start, alignItems: .stretch,
            children: [nameSection, topicSection, membersSection, spacer, createButtonNode]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16),
            child: mainStack
        )
    }
}
