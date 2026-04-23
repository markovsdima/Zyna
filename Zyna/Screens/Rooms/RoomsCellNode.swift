//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

class RoomsCellNode: ZynaCellNode {

    private let chat: RoomModel
    private let avatarImageNode = ASImageNode()
    private let avatarBackgroundNode = ASImageNode()
    private let nameNode = ASTextNode()
    private let messageNode = ASTextNode()
    private let timestampNode = ASTextNode()
    private let onlineIndicatorNode = ASImageNode()
    private static let onlineIndicatorDiameter: CGFloat = 12
    private static let onlineIndicatorBorderWidth: CGFloat = 2
    private static let avatarDiameter: CGFloat = 50
    private static let avatarThumbSize: Int = Int(avatarDiameter * ScreenConstants.scale)
    private let unreadBadgeNode = ASDisplayNode()
    private let unreadCountNode = ASTextNode()
    private let separatorNode = ASDisplayNode()

    init(chat: RoomModel) {
        self.chat = chat
        super.init()

        automaticallyManagesSubnodes = true
        setupNodes()
        setupAccessibility()
    }

    private func updateOnlineIndicatorImage() {
        onlineIndicatorNode.image = OnlineIndicatorImage.render(
            diameter: Self.onlineIndicatorDiameter,
            borderWidth: Self.onlineIndicatorBorderWidth,
            userInterfaceStyle: view.traitCollection.userInterfaceStyle
        )
    }

    /// Flips the indicator alpha without rebuilding the cell.
    /// Driven by RoomsViewModel.onInPlacePresence on presence change.
    func updatePresence(isOnline: Bool) {
        onlineIndicatorNode.alpha = isOnline ? 1 : 0
    }

    private func setupNodes() {
        // Avatar background (pre-rendered circle with baked initials)
        avatarBackgroundNode.image = chat.avatar.circleImage(diameter: 50, fontSize: 18)
        avatarBackgroundNode.isLayerBacked = true

        // Avatar image (authenticated media, loaded async)
        avatarImageNode.cornerRoundingType = .precomposited
        avatarImageNode.cornerRadius = 25
        avatarImageNode.clipsToBounds = true
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        if let mxc = chat.avatar.mxcAvatarURL {
            // Synchronous memory hit — safe from Texture's bg thread,
            // node appears with image immediately, no flash.
            if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: Self.avatarThumbSize) {
                avatarImageNode.image = cached
            } else {
                loadAvatarImage()
            }
        }

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

        // Online indicator — pre-rendered UIImage from
        // OnlineIndicatorImage, set in didLoad when the trait
        // collection is on main. Layer-backed, no cornerRadius work.
        onlineIndicatorNode.isLayerBacked = true
        onlineIndicatorNode.isOpaque = false
        onlineIndicatorNode.contentMode = .center

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

    private func loadAvatarImage() {
        guard let mxc = chat.avatar.mxcAvatarURL else { return }
        let size = Self.avatarThumbSize
        Task { [weak self] in
            if let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) {
                self?.avatarImageNode.image = image
                return
            }
            // Client may not be ready on first attempt (rooms load
            // from GRDB cache before SDK session restores).
            try? await Task.sleep(for: .seconds(1))
            guard let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) else { return }
            self?.avatarImageNode.image = image
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Avatar: pre-rendered circle background, photo overlaid on top
        avatarBackgroundNode.style.preferredSize = CGSize(width: 50, height: 50)
        avatarImageNode.style.preferredSize = CGSize(width: 50, height: 50)
        let avatar: ASLayoutSpec = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)

        // Always in layout — alpha=0 is compositor-skipped, no
        // flicker on presence flips.
        let d = Self.onlineIndicatorDiameter
        onlineIndicatorNode.style.preferredSize = CGSize(width: d, height: d)
        onlineIndicatorNode.style.layoutPosition = CGPoint(x: 38, y: 38)
        onlineIndicatorNode.alpha = chat.isOnline ? 1 : 0
        let avatarSection = ASAbsoluteLayoutSpec(children: [avatar, onlineIndicatorNode])
        avatarSection.style.preferredSize = CGSize(width: 50, height: 50)

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

    private func setupAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .button

        var label = chat.name
        if !chat.lastMessage.isEmpty {
            label += ", \(chat.lastMessage)"
        }
        if chat.unreadCount > 0 {
            label += ", \(chat.unreadCount) unread"
        }
        if chat.isOnline {
            label += ", online"
        }
        accessibilityLabel = label

        if !chat.timestamp.isEmpty {
            accessibilityValue = chat.timestamp
        }
    }

    override func didLoad() {
        super.didLoad()
        backgroundColor = UIColor.systemBackground

        let highlightedBackground = UIView()
        highlightedBackground.backgroundColor = UIColor.systemGray6
        selectedBackgroundView = highlightedBackground

        updateOnlineIndicatorImage()
        // Border depends on trait; cells aren't re-created on flip.
        // didLoad is on main but not @MainActor in the bridge.
        if #available(iOS 17, *) {
            MainActor.assumeIsolated {
                view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIView, _) in
                    self?.updateOnlineIndicatorImage()
                }
            }
        }
    }
}
