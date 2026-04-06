//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class RoomDetailsNode: ScreenNode {

    var onSearchTapped: (() -> Void)?

    // MARK: - Nodes

    private let avatarBackgroundNode = ASDisplayNode()
    private let avatarImageNode = ASImageNode()
    private let avatarInitialsNode = ASTextNode()
    private let nameNode = ASTextNode()
    private let memberCountNode = ASTextNode()
    private let searchButtonNode = ASButtonNode()

    // MARK: - State

    var topInset: CGFloat = 40
    var bottomInset: CGFloat = 16

    // MARK: - Init

    override init() {
        super.init()
        setupNodes()
    }

    // MARK: - Setup

    private func setupNodes() {
        avatarBackgroundNode.backgroundColor = .systemGray4
        avatarImageNode.clipsToBounds = true
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true

        let searchIcon = UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        )
        searchButtonNode.setImage(searchIcon, for: .normal)
        searchButtonNode.setAttributedTitle(NSAttributedString(
            string: "  Search Messages",
            attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]
        ), for: .normal)
        searchButtonNode.contentHorizontalAlignment = .middle
        searchButtonNode.addTarget(self, action: #selector(searchTapped), forControlEvents: .touchUpInside)
    }

    // MARK: - Update

    func update(name: String, memberCount: Int?, avatarMxcUrl: String?) {
        let initials = String(name.prefix(1)).uppercased()
        avatarInitialsNode.attributedText = NSAttributedString(
            string: initials,
            attributes: [
                .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )

        nameNode.attributedText = NSAttributedString(
            string: name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.label
            ]
        )

        if let count = memberCount {
            // TODO: Replace with stringsdict plural rules when adding localization
            memberCountNode.attributedText = NSAttributedString(
                string: "\(count) member\(count == 1 ? "" : "s")",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        }

        if let mxcUrl = avatarMxcUrl {
            loadAvatarImage(mxcUrl: mxcUrl)
        }

        setNeedsLayout()
    }

    private func loadAvatarImage(mxcUrl: String) {
        Task { @MainActor in
            guard let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxcUrl, size: 200) else { return }
            self.avatarImageNode.image = image
        }
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let size = CGSize(width: 100, height: 100)
        avatarBackgroundNode.style.preferredSize = size
        avatarImageNode.style.preferredSize = size

        let initialsCenter = ASCenterLayoutSpec(
            centeringOptions: .XY, sizingOptions: .minimumXY, child: avatarInitialsNode
        )
        let withInitials = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: initialsCenter)
        let avatarSpec = ASOverlayLayoutSpec(child: withInitials, overlay: avatarImageNode)

        var infoChildren: [ASLayoutElement] = [avatarSpec, nameNode]
        if memberCountNode.attributedText != nil {
            infoChildren.append(memberCountNode)
        }

        let profileStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 8,
            justifyContent: .start, alignItems: .center,
            children: infoChildren
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        searchButtonNode.style.alignSelf = .stretch

        let mainStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 0,
            justifyContent: .start, alignItems: .stretch,
            children: [profileStack, spacer, searchButtonNode]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 24, bottom: bottomInset, right: 24),
            child: mainStack
        )
    }

    // MARK: - Actions

    @objc private func searchTapped() {
        onSearchTapped?()
    }

    override func didLoad() {
        super.didLoad()
        avatarBackgroundNode.cornerRadius = 50
        avatarBackgroundNode.clipsToBounds = true
        avatarImageNode.cornerRadius = 50
        avatarImageNode.clipsToBounds = true
    }
}
