//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceLineCellNode: ZynaCellNode {
    private enum Metrics {
        static let avatarSize = CGSize(width: 38, height: 38)
        static let avatarCornerRadius: CGFloat = 9
        static let avatarThumbSize = Int(avatarSize.width * ScreenConstants.scale)
    }

    private let line: RoomModel
    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let metaNode = ASTextNode()
    private let chevronNode = ASImageNode()
    private let separatorNode = ASDisplayNode()

    init(line: RoomModel) {
        self.line = line
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
    }

    private func setupNodes() {
        backgroundColor = .systemBackground

        avatarBackgroundNode.image = line.avatar.roundedRectImage(
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            fontSize: 14
        )
        avatarBackgroundNode.isLayerBacked = true

        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        if let mxc = line.avatar.mxcAvatarURL {
            if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: Metrics.avatarThumbSize) {
                avatarImageNode.image = Self.roundedAvatarImage(cached, cacheKey: mxc)
            } else {
                loadAvatarImage()
            }
        }

        titleNode.attributedText = NSAttributedString(
            string: line.name.isEmpty ? String(localized: "Untitled") : line.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail

        metaNode.attributedText = NSAttributedString(
            string: line.spaceMetaText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.tertiaryLabel
            ]
        )
        metaNode.maximumNumberOfLines = 1
        metaNode.truncationMode = .byTruncatingTail

        chevronNode.image = AppIcon.chevronForward.template(size: 13, weight: .semibold)
        chevronNode.tintColor = .tertiaryLabel
        chevronNode.style.preferredSize = CGSize(width: 13, height: 13)

        separatorNode.backgroundColor = UIColor.separator
    }

    private func loadAvatarImage() {
        guard let mxc = line.avatar.mxcAvatarURL else { return }
        let size = Metrics.avatarThumbSize
        Task { [weak self] in
            if let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) {
                self?.avatarImageNode.image = Self.roundedAvatarImage(image, cacheKey: mxc)
                return
            }
            try? await Task.sleep(for: .seconds(1))
            guard let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) else { return }
            self?.avatarImageNode.image = Self.roundedAvatarImage(image, cacheKey: mxc)
        }
    }

    private static func roundedAvatarImage(_ image: UIImage, cacheKey: String) -> UIImage {
        RoundedImageCache.roundedImage(
            source: image,
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            cacheKey: cacheKey
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        avatarBackgroundNode.style.preferredSize = Metrics.avatarSize
        avatarImageNode.style.preferredSize = Metrics.avatarSize
        let avatar = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)

        titleNode.style.flexGrow = 1
        titleNode.style.flexShrink = 1
        metaNode.style.flexGrow = 1
        metaNode.style.flexShrink = 1

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .center,
            alignItems: .stretch,
            children: [titleNode, metaNode]
        )
        textStack.style.flexGrow = 1
        textStack.style.flexShrink = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 11,
            justifyContent: .start,
            alignItems: .center,
            children: [avatar, textStack, chevronNode]
        )

        let content = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 9, left: 16, bottom: 9, right: 16),
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
