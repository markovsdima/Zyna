//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Foundation

final class RoomDetailsNode: ScreenNode {

    var onAvatarTapped: (() -> Void)?
    var onRemoveAvatarTapped: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onInviteTapped: (() -> Void)?
    var onMembersTapped: (() -> Void)?

    /// Set by the VC after the bar is configured. Lets us put the bar
    /// first in the a11y tree — otherwise VO walks subview order and
    /// reaches the bar last (it's added on top, so it's last subview).
    weak var glassTopBar: GlassTopBar?

    // MARK: - Nodes

    /// Sampling target for the glass top bar. Without it, glass falls
    /// back to the window — which includes the glass renderer itself.
    let contentNode = ASDisplayNode()

    private let avatarBackgroundNode = ASDisplayNode()
    private let avatarImageNode = ASImageNode()
    private let avatarInitialsNode = ASTextNode()
    private let avatarTapNode = TappableNode()
    private let editAvatarOverlayNode = ASDisplayNode()
    private let editAvatarIconNode = ASImageNode()
    private let removeAvatarButtonNode = AccessibleButtonNode()

    private let nameNode = ASTextNode()
    private let nameEditNode = ASEditableTextNode()

    /// Tap target for the members list. Visible chevron + pill bg
    /// makes the affordance obvious — a plain text count looks like
    /// a label, not a button.
    private let membersRowBackground = RoundedBackgroundNode()
    private let membersRow = TappableNode()
    private let membersRowText = ASTextNode()
    private let membersRowChevron = ASImageNode()

    private let inviteButtonNode = AccessibleButtonNode()
    private let searchButtonNode = AccessibleButtonNode()

    // MARK: - State

    var topInset: CGFloat = 40
    var bottomInset: CGFloat = 16

    private var isEditing = false
    private var hasAvatar = false
    private var avatarLoadRevision: UInt64 = 0

    var editingName: String? {
        nameEditNode.attributedText?.string
    }

    // MARK: - Init

    override init() {
        super.init()
        setupNodes()
    }

    // MARK: - Setup

    private func setupNodes() {
        avatarBackgroundNode.backgroundColor = .systemGray4
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        avatarImageNode.isOpaque = false

        avatarTapNode.backgroundColor = .clear
        avatarTapNode.onTap = { [weak self] in self?.onAvatarTapped?() }
        avatarTapNode.isAccessibilityElement = false
        avatarTapNode.accessibilityTraits = .button
        avatarTapNode.accessibilityLabel = "Change group avatar"

        editAvatarOverlayNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        editAvatarOverlayNode.isHidden = true
        editAvatarIconNode.image = UIImage(systemName: "camera.fill")
        editAvatarIconNode.imageModificationBlock = ASImageNodeTintColorModificationBlock(.white)
        editAvatarIconNode.contentMode = .scaleAspectFit

        removeAvatarButtonNode.setImage(
            AppIcon.xmark.rendered(size: 12, weight: .bold, color: .white),
            for: .normal
        )
        removeAvatarButtonNode.backgroundColor = .systemRed
        removeAvatarButtonNode.style.preferredSize = CGSize(width: 28, height: 28)
        removeAvatarButtonNode.addTarget(
            self,
            action: #selector(removeAvatarTapped),
            forControlEvents: .touchUpInside
        )
        removeAvatarButtonNode.isAccessibilityElement = true
        removeAvatarButtonNode.accessibilityTraits = .button
        removeAvatarButtonNode.accessibilityLabel = "Remove group avatar"
        removeAvatarButtonNode.isHidden = true

        nameEditNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 22, weight: .bold),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.label
        ]
        nameEditNode.textContainerInset = .zero

        searchButtonNode.setAttributedTitle(NSAttributedString(
            string: "  " + String(localized: "Search Messages"),
            attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]
        ), for: .normal)
        searchButtonNode.contentHorizontalAlignment = .middle
        searchButtonNode.addTarget(self, action: #selector(searchTapped), forControlEvents: .touchUpInside)

        inviteButtonNode.setAttributedTitle(NSAttributedString(
            string: "  " + String(localized: "Invite Members"),
            attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]
        ), for: .normal)
        inviteButtonNode.contentHorizontalAlignment = .middle
        inviteButtonNode.addTarget(self, action: #selector(inviteTapped), forControlEvents: .touchUpInside)

        membersRowBackground.fillColor = .secondarySystemBackground
        membersRowBackground.radius = 12
        membersRow.backgroundColor = .clear
        membersRow.onTap = { [weak self] in self?.onMembersTapped?() }
        membersRow.isAccessibilityElement = true
        membersRow.accessibilityTraits = .button
        membersRowText.maximumNumberOfLines = 1
        membersRowChevron.style.preferredSize = CGSize(width: 12, height: 12)
    }

    // MARK: - Update

    func update(name: String, memberCount: Int?, avatarMxcUrl: String?) {
        hasAvatar = avatarMxcUrl != nil
        avatarLoadRevision &+= 1
        let loadRevision = avatarLoadRevision
        applyName(name)

        if let count = memberCount {
            membersRowText.attributedText = NSAttributedString(
                string: String(localized: "\(count) members"),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]
            )
            membersRow.accessibilityLabel = String(localized: "\(count) members")
            membersRow.accessibilityHint = String(localized: "Opens the member list")
        }

        if let mxcUrl = avatarMxcUrl {
            loadAvatarImage(mxcUrl: mxcUrl, revision: loadRevision)
        } else {
            avatarImageNode.image = nil
            setBackgroundVisible(true)
        }

        removeAvatarButtonNode.isHidden = !(isEditing && hasAvatar)
        setNeedsLayout()
    }

    func updateAvatarLocally(image: UIImage) {
        hasAvatar = true
        avatarLoadRevision &+= 1
        avatarImageNode.image = CircularImageCache.roundedImage(
            source: image, diameter: 100, cacheKey: UUID().uuidString
        )
        setBackgroundVisible(false)
        removeAvatarButtonNode.isHidden = !isEditing
        setNeedsLayout()
    }

    func removeAvatarLocally() {
        hasAvatar = false
        avatarLoadRevision &+= 1
        avatarImageNode.image = nil
        setBackgroundVisible(true)
        removeAvatarButtonNode.isHidden = true
        setNeedsLayout()
    }

    func updateNameLocally(_ name: String) {
        applyName(name)
        setNeedsLayout()
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
        editAvatarOverlayNode.isHidden = !editing
        avatarTapNode.isAccessibilityElement = editing
        removeAvatarButtonNode.isHidden = !(editing && hasAvatar)
        setNeedsLayout()
    }

    private func applyName(_ name: String) {
        let initials = String(name.prefix(1)).uppercased()
        avatarInitialsNode.attributedText = NSAttributedString(
            string: initials,
            attributes: [
                .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        nameNode.attributedText = NSAttributedString(string: name, attributes: attrs)
        nameEditNode.attributedText = NSAttributedString(string: name, attributes: attrs)
    }

    private func loadAvatarImage(mxcUrl: String, revision: UInt64) {
        // Fetch + circle bake stay off-main. Both UIKit mutations
        // (image set + bg hide) land in the same main-thread tick so
        // the bg disappears in the same frame the image appears —
        // otherwise a single frame can leak the antialiased ring.
        let pixelSize = Int(100 * ScreenConstants.scale)
        Task { [weak self] in
            guard let source = await MediaCache.shared.loadThumbnail(mxcUrl: mxcUrl, size: pixelSize) else { return }
            let rounded = CircularImageCache.roundedImage(
                source: source, diameter: 100, cacheKey: mxcUrl
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.avatarLoadRevision == revision else { return }
                self.avatarImageNode.image = rounded
                self.setBackgroundVisible(false)
            }
        }
    }

    /// Bg + initials show only when there's no avatar image. Hiding
    /// (rather than alpha=0) skips the layer from compositing entirely.
    private func setBackgroundVisible(_ visible: Bool) {
        avatarBackgroundNode.isHidden = !visible
        avatarInitialsNode.isHidden = !visible
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let size = CGSize(width: 100, height: 100)
        avatarBackgroundNode.style.preferredSize = size
        avatarImageNode.style.preferredSize = size
        avatarTapNode.style.preferredSize = size
        editAvatarOverlayNode.style.preferredSize = size
        editAvatarIconNode.style.preferredSize = CGSize(width: 28, height: 28)

        let initialsCenter = ASCenterLayoutSpec(
            centeringOptions: .XY, sizingOptions: .minimumXY, child: avatarInitialsNode
        )
        let withInitials = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: initialsCenter)
        var avatarSpec: ASLayoutSpec = ASOverlayLayoutSpec(child: withInitials, overlay: avatarImageNode)

        if isEditing {
            let iconCenter = ASCenterLayoutSpec(
                centeringOptions: .XY,
                sizingOptions: .minimumXY,
                child: editAvatarIconNode
            )
            let overlay = ASOverlayLayoutSpec(child: editAvatarOverlayNode, overlay: iconCenter)
            avatarSpec = ASOverlayLayoutSpec(child: avatarSpec, overlay: overlay)
            avatarSpec = ASOverlayLayoutSpec(child: avatarSpec, overlay: avatarTapNode)

            if hasAvatar {
                removeAvatarButtonNode.style.layoutPosition = CGPoint(x: size.width - 22, y: -6)
                avatarSpec = ASAbsoluteLayoutSpec(
                    sizing: .sizeToFit,
                    children: [avatarSpec, removeAvatarButtonNode]
                )
            }
        }

        let nameSpec: ASLayoutSpec
        if isEditing {
            nameEditNode.style.minWidth = ASDimension(unit: .points, value: 150)
            nameSpec = ASWrapperLayoutSpec(layoutElement: nameEditNode)
        } else {
            nameSpec = ASWrapperLayoutSpec(layoutElement: nameNode)
        }

        let profileStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 8,
            justifyContent: .start, alignItems: .center,
            children: [avatarSpec, nameSpec]
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        inviteButtonNode.style.alignSelf = .stretch
        searchButtonNode.style.alignSelf = .stretch

        var membersRowChildren: [ASLayoutElement] = [membersRowText]
        let pushChevron = ASLayoutSpec()
        pushChevron.style.flexGrow = 1
        membersRowChildren.append(pushChevron)
        membersRowChildren.append(membersRowChevron)
        let membersRowContent = ASStackLayoutSpec(
            direction: .horizontal, spacing: 8,
            justifyContent: .start, alignItems: .center,
            children: membersRowChildren
        )
        let membersRowPadded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16),
            child: membersRowContent
        )
        let membersRowWithBg = ASBackgroundLayoutSpec(child: membersRowPadded, background: membersRowBackground)
        let membersRowSpec = ASOverlayLayoutSpec(child: membersRowWithBg, overlay: membersRow)
        membersRowSpec.style.alignSelf = .stretch

        var buttonsChildren: [ASLayoutElement] = []
        if membersRowText.attributedText != nil {
            buttonsChildren.append(membersRowSpec)
        }
        buttonsChildren.append(contentsOf: [inviteButtonNode, searchButtonNode])

        let buttonsStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 24,
            justifyContent: .start, alignItems: .stretch,
            children: buttonsChildren
        )

        let mainStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 0,
            justifyContent: .start, alignItems: .stretch,
            children: [profileStack, spacer, buttonsStack]
        )

        let inset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 24, bottom: bottomInset, right: 24),
            child: mainStack
        )
        return ASBackgroundLayoutSpec(child: inset, background: contentNode)
    }

    // MARK: - Actions

    @objc private func searchTapped() {
        onSearchTapped?()
    }

    @objc private func inviteTapped() {
        onInviteTapped?()
    }

    @objc private func removeAvatarTapped() {
        onRemoveAvatarTapped?()
    }

    override func didLoad() {
        super.didLoad()
        // No mask on avatarImageNode — it renders a pre-rounded image
        // (corners baked into the bitmap). Two overlapping circular
        // masks would leak a 1-2px antialiased ring of the bg through
        // the seam. Bg keeps its mask because it's used as a fallback
        // when no avatar image is present.
        avatarBackgroundNode.cornerRadius = 50
        avatarBackgroundNode.clipsToBounds = true
        editAvatarOverlayNode.cornerRadius = 50
        editAvatarOverlayNode.clipsToBounds = true
        removeAvatarButtonNode.cornerRadius = 14
        removeAvatarButtonNode.clipsToBounds = true

        searchButtonNode.setImage(
            AppIcon.magnifyingGlass.rendered(size: 16, weight: .medium, color: AppColor.accent),
            for: .normal
        )
        inviteButtonNode.setImage(
            AppIcon.personBadgePlus.rendered(size: 16, weight: .medium, color: AppColor.accent),
            for: .normal
        )
        membersRowChevron.image = AppIcon.chevronForward.rendered(
            size: 12, weight: .semibold, color: .tertiaryLabel
        )
    }

    // MARK: - Accessibility

    /// Bar before content. Default subview-walk would put the bar last
    /// (it's the topmost subview), so VO swipe order would reach it
    /// only after stepping through avatar/name/membersRow.
    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar, bar.view.superview === view {
                elements.append(contentsOf: bar.accessibilityElementsInOrder)
            }
            for sv in view.subviews where sv !== glassTopBar?.view {
                elements.append(sv)
            }
            return elements
        }
        set { }
    }
}
