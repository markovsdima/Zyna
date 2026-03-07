//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ProfileNode: BaseNode {

    var onLogoutTapped: (() -> Void)?

    private let avatarBackgroundNode = ASDisplayNode()
    private let avatarImageNode = ASNetworkImageNode()
    private let avatarInitialsNode = ASTextNode()
    private let displayNameNode = ASTextNode()
    private let userIdNode = ASTextNode()
    private let logoutButtonNode = ASButtonNode()

    private var hasAvatar = false
    var topInset: CGFloat = 40
    var bottomInset: CGFloat = 16

    override init() {
        super.init()
        setupNodes()
    }

    override func didLoad() {
        super.didLoad()
        avatarBackgroundNode.cornerRadius = 40
        avatarBackgroundNode.clipsToBounds = true
        avatarImageNode.cornerRadius = 40
        avatarImageNode.clipsToBounds = true
        logoutButtonNode.cornerRadius = 12
        logoutButtonNode.clipsToBounds = true
    }

    // MARK: - Public

    func update(displayName: String?, userId: String?, avatarUrl: URL?) {
        let name = displayName ?? userId ?? ""

        displayNameNode.attributedText = NSAttributedString(
            string: name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.label
            ]
        )

        userIdNode.attributedText = NSAttributedString(
            string: userId ?? "",
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )

        let initials = Self.initials(from: displayName ?? userId ?? "?")
        avatarInitialsNode.attributedText = NSAttributedString(
            string: initials,
            attributes: [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )

        if let avatarUrl {
            hasAvatar = true
            avatarImageNode.url = avatarUrl
        }

        setNeedsLayout()
    }

    // MARK: - Setup

    private func setupNodes() {
        avatarBackgroundNode.backgroundColor = .systemGray4

        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.shouldRenderProgressImages = false

        let logoutTitle = NSAttributedString(
            string: "Выйти",
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )
        logoutButtonNode.setAttributedTitle(logoutTitle, for: .normal)
        logoutButtonNode.backgroundColor = .systemRed
        logoutButtonNode.contentEdgeInsets = UIEdgeInsets(top: 14, left: 32, bottom: 14, right: 32)
        logoutButtonNode.addTarget(self, action: #selector(logoutTapped), forControlEvents: .touchUpInside)
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Avatar
        avatarBackgroundNode.style.preferredSize = CGSize(width: 80, height: 80)
        avatarImageNode.style.preferredSize = CGSize(width: 80, height: 80)

        let initialsCenter = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: .minimumXY,
            child: avatarInitialsNode
        )
        var avatarSpec: ASLayoutSpec = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: initialsCenter)
        if hasAvatar {
            avatarSpec = ASOverlayLayoutSpec(child: avatarSpec, overlay: avatarImageNode)
        }

        // Profile info
        let profileStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 6,
            justifyContent: .start,
            alignItems: .center,
            children: [avatarSpec, displayNameNode, userIdNode]
        )

        // Spacer
        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        // Button
        logoutButtonNode.style.alignSelf = .stretch

        // Main stack
        let mainStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [profileStack, spacer, logoutButtonNode]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 24, bottom: bottomInset, right: 24),
            child: mainStack
        )
    }

    // MARK: - Actions

    @objc private func logoutTapped() {
        onLogoutTapped?()
    }

    // MARK: - Helpers

    private static func initials(from name: String) -> String {
        let cleaned = name.hasPrefix("@") ? String(name.dropFirst()) : name
        let parts = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(cleaned.prefix(2)).uppercased()
    }
}
