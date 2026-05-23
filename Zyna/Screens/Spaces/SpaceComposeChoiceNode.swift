//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceComposeChoiceNode: ScreenNode {

    let cancelButtonNode = ASButtonNode()
    let existingChatOptionNode: SpaceComposeOptionNode
    let chatOptionNode: SpaceComposeOptionNode
    let trackOptionNode: SpaceComposeOptionNode

    var topInset: CGFloat = 0 {
        didSet {
            guard abs(topInset - oldValue) > 0.5 else { return }
            setNeedsLayout()
        }
    }

    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let parent: RoomModel
    private let presentation: SpacePresentationKind

    init(parent: RoomModel, presentation: SpacePresentationKind) {
        self.parent = parent
        self.presentation = presentation
        self.existingChatOptionNode = SpaceComposeOptionNode(
            icon: AppIcon.link.rendered(size: 22, weight: .semibold, color: .systemBlue),
            title: String(localized: "Existing Chat"),
            subtitle: String(localized: "Place one of your current chats here. It can still appear elsewhere.")
        )
        self.chatOptionNode = SpaceComposeOptionNode(
            icon: AppIcon.bubbleLeft.rendered(size: 22, weight: .semibold, color: .systemBlue),
            title: String(localized: "New Chat"),
            subtitle: String(localized: "Create a regular chat and place it inside this \(presentation.title).")
        )
        self.trackOptionNode = SpaceComposeOptionNode(
            icon: AppIcon.compose.rendered(size: 22, weight: .semibold, color: .systemPurple),
            title: String(localized: "New Track"),
            subtitle: String(localized: "Create a nested direction for related chats.")
        )

        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .systemBackground
        setupNodes()
    }

    private func setupNodes() {
        cancelButtonNode.setTitle(
            String(localized: "Cancel"),
            with: UIFont.systemFont(ofSize: 17, weight: .regular),
            with: .systemBlue,
            for: .normal
        )

        titleNode.attributedText = NSAttributedString(
            string: String(localized: "Add to \(presentation.title)"),
            attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail

        let parentName = parent.name.isEmpty ? String(localized: "Untitled") : parent.name
        subtitleNode.attributedText = NSAttributedString(
            string: String(localized: "Choose what to add inside \(parentName)."),
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        subtitleNode.maximumNumberOfLines = 0
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        cancelButtonNode.style.height = ASDimension(unit: .points, value: 44)
        cancelButtonNode.style.minWidth = ASDimension(unit: .points, value: 68)

        let headerSpacer = ASLayoutSpec()
        headerSpacer.style.flexGrow = 1

        let header = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 0,
            justifyContent: .end,
            alignItems: .center,
            children: [headerSpacer, cancelButtonNode]
        )
        header.style.height = ASDimension(unit: .points, value: 44)

        let intro = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 8,
            justifyContent: .start,
            alignItems: .stretch,
            children: [titleNode, subtitleNode]
        )

        let options = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 10,
            justifyContent: .start,
            alignItems: .stretch,
            children: [existingChatOptionNode, chatOptionNode, trackOptionNode]
        )

        let content = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 22,
            justifyContent: .start,
            alignItems: .stretch,
            children: [header, intro, options]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 16, bottom: 24, right: 16),
            child: content
        )
    }
}

final class SpaceComposeOptionNode: TappableNode {

    private let backgroundNode = RoundedBackgroundNode()
    private let iconContainerNode = ASDisplayNode()
    private let iconNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let chevronNode = ASImageNode()

    init(icon: UIImage, title: String, subtitle: String) {
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes(icon: icon, title: title, subtitle: subtitle)
    }

    private func setupNodes(icon: UIImage, title: String, subtitle: String) {
        backgroundNode.fillColor = .secondarySystemBackground
        backgroundNode.radius = 12

        iconContainerNode.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.10)
        iconContainerNode.cornerRadius = 12
        iconContainerNode.clipsToBounds = true

        iconNode.image = icon
        iconNode.contentMode = .center

        titleNode.attributedText = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        titleNode.maximumNumberOfLines = 1

        subtitleNode.attributedText = NSAttributedString(
            string: subtitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        subtitleNode.maximumNumberOfLines = 0

        chevronNode.image = AppIcon.chevronForward.template(size: 14, weight: .semibold)
        chevronNode.imageModificationBlock = ASImageNodeTintColorModificationBlock(.tertiaryLabel)
        chevronNode.contentMode = .center

        isAccessibilityElement = true
        accessibilityLabel = "\(title). \(subtitle)"
        accessibilityTraits = .button
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        iconContainerNode.style.preferredSize = CGSize(width: 44, height: 44)
        iconNode.style.preferredSize = CGSize(width: 44, height: 44)
        chevronNode.style.preferredSize = CGSize(width: 18, height: 18)

        let icon = ASBackgroundLayoutSpec(child: iconNode, background: iconContainerNode)

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 4,
            justifyContent: .center,
            alignItems: .stretch,
            children: [titleNode, subtitleNode]
        )
        textStack.style.flexGrow = 1
        textStack.style.flexShrink = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: [icon, textStack, chevronNode]
        )

        let inset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 12),
            child: row
        )
        return ASBackgroundLayoutSpec(child: inset, background: backgroundNode)
    }
}
