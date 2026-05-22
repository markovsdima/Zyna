//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceHeaderCellNode: ZynaCellNode {
    private enum Metrics {
        static let avatarSize = CGSize(width: 50, height: 50)
        static let avatarCornerRadius: CGFloat = 12
        static let avatarThumbSize = Int(avatarSize.width * ScreenConstants.scale)
    }

    private let space: RoomModel
    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let metaNode = ASTextNode()
    private let separatorNode = ASDisplayNode()

    init(space: RoomModel) {
        self.space = space
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
    }

    private func setupNodes() {
        backgroundColor = .systemBackground

        avatarBackgroundNode.image = space.avatar.roundedRectImage(
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            fontSize: 17
        )
        avatarBackgroundNode.isLayerBacked = true

        avatarImageNode.cornerRoundingType = .precomposited
        avatarImageNode.cornerRadius = Metrics.avatarCornerRadius
        avatarImageNode.clipsToBounds = true
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        if let mxc = space.avatar.mxcAvatarURL {
            if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: Metrics.avatarThumbSize) {
                avatarImageNode.image = cached
            } else {
                loadAvatarImage()
            }
        }

        metaNode.attributedText = NSAttributedString(
            string: space.spaceMetaText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        metaNode.maximumNumberOfLines = 1
        metaNode.truncationMode = .byTruncatingTail

        separatorNode.backgroundColor = UIColor.separator
    }

    private func loadAvatarImage() {
        guard let mxc = space.avatar.mxcAvatarURL else { return }
        let size = Metrics.avatarThumbSize
        Task { [weak self] in
            if let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) {
                self?.avatarImageNode.image = image
                return
            }
            try? await Task.sleep(for: .seconds(1))
            guard let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) else { return }
            self?.avatarImageNode.image = image
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        avatarBackgroundNode.style.preferredSize = Metrics.avatarSize
        avatarImageNode.style.preferredSize = Metrics.avatarSize
        let avatar = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)

        metaNode.style.flexGrow = 1
        metaNode.style.flexShrink = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: [avatar, metaNode]
        )

        let content = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16),
            child: row
        )

        separatorNode.style.preferredSize = CGSize(width: constrainedSize.max.width, height: 0.5)
        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [content, separatorNode]
        )
    }
}
