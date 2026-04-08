//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class CallsCellNode: ASCellNode {

    var onCallButtonTapped: (() -> Void)?

    private let avatarBackgroundNode = ASDisplayNode()
    private let avatarTextNode = ASTextNode()
    private let avatarImageNode = ASImageNode()
    private let nameNode = ASTextNode()
    private let statusNode = ASTextNode()
    private let timeNode = ASTextNode()
    private let callButtonNode = ASButtonNode()
    private let separatorNode = ASDisplayNode()

    private static let callIcon = AppIcon.phone.rendered(size: 18, color: .systemBlue)

    private let model: CallHistoryModel

    init(model: CallHistoryModel) {
        self.model = model
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
    }

    private func setupNodes() {
        // Avatar
        avatarBackgroundNode.backgroundColor = model.avatar.color
        avatarBackgroundNode.cornerRadius = 22
        avatarBackgroundNode.borderWidth = 0.5
        avatarBackgroundNode.borderColor = UIColor.separator.cgColor

        avatarTextNode.attributedText = NSAttributedString(
            string: model.avatar.initials,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: UIColor.white
            ]
        )

        avatarImageNode.cornerRadius = 22
        avatarImageNode.clipsToBounds = true
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        if model.avatar.mxcAvatarURL != nil {
            loadAvatarImage()
        }

        // Name
        let nameColor: UIColor = model.isMissed ? .systemRed : .label
        nameNode.attributedText = NSAttributedString(
            string: model.roomName,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: nameColor
            ]
        )
        nameNode.maximumNumberOfLines = 1
        nameNode.truncationMode = .byTruncatingTail

        // Status line: "Outgoing · Call ended"
        let icon = model.isMissed ? "phone.arrow.down.left" : "phone"
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let iconImage = UIImage(systemName: icon, withConfiguration: iconConfig)?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)

        let statusString = NSMutableAttributedString()
        if let iconImage {
            let attachment = NSTextAttachment()
            attachment.image = iconImage
            statusString.append(NSAttributedString(attachment: attachment))
            statusString.append(NSAttributedString(string: " "))
        }
        statusString.append(NSAttributedString(
            string: model.statusText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        ))
        statusNode.attributedText = statusString
        statusNode.maximumNumberOfLines = 1

        // Time
        timeNode.attributedText = NSAttributedString(
            string: model.formattedTime,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.tertiaryLabel
            ]
        )

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
        onCallButtonTapped?()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Avatar
        avatarBackgroundNode.style.preferredSize = CGSize(width: 44, height: 44)
        avatarImageNode.style.preferredSize = CGSize(width: 44, height: 44)
        let initials = ASCenterLayoutSpec(
            centeringOptions: .XY, sizingOptions: .minimumXY,
            child: avatarTextNode
        )
        let withInitials = ASOverlayLayoutSpec(
            child: avatarBackgroundNode, overlay: initials
        )
        let avatar = ASOverlayLayoutSpec(
            child: withInitials, overlay: avatarImageNode
        )

        // Text column: name + status
        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .center,
            alignItems: .start,
            children: [nameNode, statusNode]
        )
        textStack.style.flexShrink = 1
        textStack.style.flexGrow = 1

        // Right side: time + call button
        callButtonNode.style.preferredSize = CGSize(width: 44, height: 44)

        let rightStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .end,
            alignItems: .center,
            children: [timeNode, callButtonNode]
        )

        // Main row
        let mainRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: [avatar, textStack, rightStack]
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

    override func didLoad() {
        super.didLoad()
        backgroundColor = .systemBackground

        let highlighted = UIView()
        highlighted.backgroundColor = .systemGray6
        selectedBackgroundView = highlighted
    }
}
