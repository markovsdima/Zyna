//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ContactsCellNode: ZynaCellNode {

    var onCallTapped: (() -> Void)?

    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let nameNode = ASTextNode()
    private let userIdNode = ASTextNode()
    private let callButtonNode = ASButtonNode()
    private let separatorNode = ASDisplayNode()

    private static let callIcon = AppIcon.phone.rendered(size: 18, color: .systemBlue)

    private let model: ContactModel

    init(model: ContactModel) {
        self.model = model
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
        setupAccessibility()
    }

    private func setupNodes() {
        // Avatar background (pre-rendered circle with baked initials)
        avatarBackgroundNode.image = model.avatar.circleImage(diameter: 44, fontSize: 16)
        avatarBackgroundNode.isLayerBacked = true

        avatarImageNode.cornerRoundingType = .precomposited
        avatarImageNode.cornerRadius = 22
        avatarImageNode.clipsToBounds = true
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        if model.avatar.mxcAvatarURL != nil {
            loadAvatarImage()
        }

        // Name
        nameNode.attributedText = NSAttributedString(
            string: model.displayName,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        nameNode.maximumNumberOfLines = 1
        nameNode.truncationMode = .byTruncatingTail

        // User ID
        userIdNode.attributedText = NSAttributedString(
            string: model.userId,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        userIdNode.maximumNumberOfLines = 1
        userIdNode.truncationMode = .byTruncatingTail

        // Call button
        callButtonNode.setImage(Self.callIcon, for: .normal)
        callButtonNode.addTarget(
            self, action: #selector(callButtonPressed),
            forControlEvents: .touchUpInside
        )

        // Separator
        separatorNode.backgroundColor = .separator
    }

    private func loadAvatarImage() {
        guard let mxc = model.avatar.mxcAvatarURL else { return }
        Task { @MainActor in
            guard let image = await MediaCache.shared.loadThumbnail(
                mxcUrl: mxc, size: 88
            ) else { return }
            self.avatarImageNode.image = image
        }
    }

    @objc private func callButtonPressed() {
        onCallTapped?()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        avatarBackgroundNode.style.preferredSize = CGSize(width: 44, height: 44)
        avatarImageNode.style.preferredSize = CGSize(width: 44, height: 44)
        let avatar = ASOverlayLayoutSpec(
            child: avatarBackgroundNode, overlay: avatarImageNode
        )

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .center,
            alignItems: .start,
            children: [nameNode, userIdNode]
        )
        textStack.style.flexShrink = 1
        textStack.style.flexGrow = 1

        callButtonNode.style.preferredSize = CGSize(width: 44, height: 44)

        let mainRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: [avatar, textStack, callButtonNode]
        )

        let contentInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16),
            child: mainRow
        )

        separatorNode.style.preferredSize = CGSize(
            width: constrainedSize.max.width, height: 0.5
        )

        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [contentInset, separatorNode]
        )
    }

    private func setupAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = model.displayName
        accessibilityValue = model.userId

        callButtonNode.accessibilityLabel = "Call \(model.displayName)"
    }

    override func didLoad() {
        super.didLoad()
        backgroundColor = .systemBackground

        let highlighted = UIView()
        highlighted.backgroundColor = .systemGray6
        selectedBackgroundView = highlighted
    }
}
