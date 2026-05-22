//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceCellNode: ZynaCellNode {

    fileprivate enum Metrics {
        static let avatarSize = CGSize(width: 50, height: 50)
        static let avatarCornerRadius: CGFloat = 12
        static let childAvatarDiameter: CGFloat = 18
        static let avatarThumbSize = Int(avatarSize.width * ScreenConstants.scale)
        static let childAvatarThumbSize = Int(childAvatarDiameter * ScreenConstants.scale)
    }

    private let space: RoomModel
    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let metaNode = ASTextNode()
    private let latestMessageNode = ASTextNode()
    private let unreadBadgeNode = ASDisplayNode()
    private let unreadCountNode = ASTextNode()
    private let separatorNode = ASDisplayNode()
    private var recentRoomNodes: [SpaceRecentRoomNode] = []

    init(space: RoomModel) {
        self.space = space
        super.init()

        automaticallyManagesSubnodes = true
        setupNodes()
        setupAccessibility()
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

        titleNode.attributedText = NSAttributedString(
            string: space.name.isEmpty ? String(localized: "Untitled") : space.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail

        metaNode.attributedText = NSAttributedString(
            string: Self.metaText(for: space),
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.tertiaryLabel
            ]
        )
        metaNode.maximumNumberOfLines = 1
        metaNode.truncationMode = .byTruncatingTail

        latestMessageNode.attributedText = NSAttributedString(
            string: Self.latestMessageText(for: space),
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        latestMessageNode.maximumNumberOfLines = 1
        latestMessageNode.truncationMode = .byTruncatingTail

        unreadBadgeNode.backgroundColor = space.unreadBadgeUsesAttentionStyle
            ? UIColor.systemRed
            : UIColor.systemBlue
        if let badgeText = space.unreadBadgeText {
            unreadCountNode.attributedText = NSAttributedString(
                string: badgeText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.white
                ]
            )
            unreadCountNode.maximumNumberOfLines = 1
        }

        recentRoomNodes = space.spaceRecentRooms.map { SpaceRecentRoomNode(room: $0) }
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

        titleNode.style.flexGrow = 1
        titleNode.style.flexShrink = 1

        var rightColumnChildren: [ASLayoutElement] = [metaNode]
        if space.showsUnreadBadge {
            rightColumnChildren.append(buildUnreadBadge())
        }

        let rightColumn = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 5,
            justifyContent: .start,
            alignItems: .end,
            children: rightColumnChildren
        )

        let titleRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 10,
            justifyContent: .start,
            alignItems: .start,
            children: [titleNode, rightColumn]
        )

        let recentRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .center,
            children: recentRoomNodes
        )
        recentRow.style.flexShrink = 1

        let bottomStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 1,
            justifyContent: .start,
            alignItems: .stretch,
            children: [latestMessageNode]
        )

        var detailChildren: [ASLayoutElement] = [titleRow]
        if !recentRoomNodes.isEmpty {
            detailChildren.append(recentRow)
        }
        detailChildren.append(bottomStack)

        let detailStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 7,
            justifyContent: .start,
            alignItems: .stretch,
            children: detailChildren
        )
        detailStack.style.flexGrow = 1
        detailStack.style.flexShrink = 1

        let mainContent = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .start,
            children: [avatar, detailStack]
        )

        let contentInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16),
            child: mainContent
        )

        separatorNode.style.preferredSize = CGSize(width: constrainedSize.max.width, height: 0.5)

        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [contentInset, separatorNode]
        )
    }

    private func buildUnreadBadge() -> ASLayoutSpec {
        if let badgeText = space.unreadBadgeText {
            let badgeTextSize = badgeText.size(withAttributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium)
            ])
            unreadBadgeNode.style.preferredSize = CGSize(
                width: max(22, ceil(badgeTextSize.width) + 12),
                height: 22
            )
            unreadBadgeNode.cornerRadius = 11
            let center = ASCenterLayoutSpec(
                centeringOptions: .XY,
                sizingOptions: .minimumXY,
                child: unreadCountNode
            )
            return ASOverlayLayoutSpec(child: unreadBadgeNode, overlay: center)
        }

        unreadBadgeNode.style.preferredSize = CGSize(width: 10, height: 10)
        unreadBadgeNode.cornerRadius = 5
        return ASWrapperLayoutSpec(layoutElement: unreadBadgeNode)
    }

    private func setupAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .button

        var label = "\(space.name), \(String(localized: "storyline")), \(Self.metaText(for: space))"
        if space.unreadCount > 0 {
            label += ", \(space.unreadCount) unread"
        } else if space.isMarkedUnread {
            label += ", unread"
        }
        if space.unreadMentionCount > 0 {
            label += ", \(space.unreadMentionCount) mentions"
        }
        accessibilityLabel = label
        accessibilityValue = Self.latestMessageText(for: space)
    }

    override func didLoad() {
        super.didLoad()
        backgroundColor = UIColor.systemBackground

        let highlightedBackground = UIView()
        highlightedBackground.backgroundColor = UIColor.systemGray6
        selectedBackgroundView = highlightedBackground
    }

    private static func metaText(for space: RoomModel) -> String {
        let chats = String.localizedStringWithFormat(
            String(localized: "%lld chats"),
            Int64(space.spaceChildRoomCount)
        )
        let tracks = String.localizedStringWithFormat(
            String(localized: "%lld tracks"),
            Int64(space.spaceChildSpaceCount)
        )
        return "\(chats) · \(tracks)"
    }

    private static func latestMessageText(for space: RoomModel) -> String {
        guard !space.lastMessage.isEmpty else {
            if !space.spaceRecentRooms.isEmpty {
                return String(localized: "No messages")
            }
            return space.spaceChildRoomCount > 0
                ? String(localized: "No accessible chats")
                : String(localized: "Add the first chat")
        }

        if let sender = space.lastMessageSenderName, !sender.isEmpty {
            return "\(sender): \(space.lastMessage)"
        }

        return space.lastMessage
    }

}

private final class SpaceRecentRoomNode: ASDisplayNode {
    private let room: SpaceChildModel
    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let titleNode = ASTextNode()

    init(room: SpaceChildModel) {
        self.room = room
        super.init()
        automaticallyManagesSubnodes = true

        avatarBackgroundNode.image = room.avatar.circleImage(
            diameter: SpaceCellNode.Metrics.childAvatarDiameter,
            fontSize: 8
        )
        avatarBackgroundNode.isLayerBacked = true

        avatarImageNode.cornerRoundingType = .precomposited
        avatarImageNode.cornerRadius = SpaceCellNode.Metrics.childAvatarDiameter / 2
        avatarImageNode.clipsToBounds = true
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        if let mxc = room.avatar.mxcAvatarURL {
            if let cached = MediaCache.shared.cachedImage(
                forUrl: mxc,
                size: SpaceCellNode.Metrics.childAvatarThumbSize
            ) {
                avatarImageNode.image = CircularImageCache.roundedImage(
                    source: cached,
                    diameter: SpaceCellNode.Metrics.childAvatarDiameter,
                    cacheKey: "\(mxc):space-child"
                )
            } else {
                loadAvatarImage()
            }
        }

        titleNode.attributedText = NSAttributedString(
            string: room.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.label.withAlphaComponent(0.82)
            ]
        )
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail
    }

    private func loadAvatarImage() {
        guard let mxc = room.avatar.mxcAvatarURL else { return }
        let size = SpaceCellNode.Metrics.childAvatarThumbSize
        Task { [weak self] in
            guard let image = await MediaCache.shared.loadThumbnail(
                mxcUrl: mxc,
                size: size
            ) else {
                try? await Task.sleep(for: .seconds(1))
                guard let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) else { return }
                self?.avatarImageNode.image = CircularImageCache.roundedImage(
                    source: image,
                    diameter: SpaceCellNode.Metrics.childAvatarDiameter,
                    cacheKey: "\(mxc):space-child"
                )
                return
            }
            self?.avatarImageNode.image = CircularImageCache.roundedImage(
                source: image,
                diameter: SpaceCellNode.Metrics.childAvatarDiameter,
                cacheKey: "\(mxc):space-child"
            )
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        avatarBackgroundNode.style.preferredSize = CGSize(
            width: SpaceCellNode.Metrics.childAvatarDiameter,
            height: SpaceCellNode.Metrics.childAvatarDiameter
        )
        avatarImageNode.style.preferredSize = avatarBackgroundNode.style.preferredSize
        let avatar = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)

        titleNode.style.flexShrink = 1
        titleNode.style.maxWidth = ASDimension(unit: .points, value: 86)

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 4,
            justifyContent: .start,
            alignItems: .center,
            children: [avatar, titleNode]
        )
        row.style.flexShrink = 1
        return row
    }
}
