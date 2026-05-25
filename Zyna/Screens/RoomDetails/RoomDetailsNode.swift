//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Foundation

struct RoomDetailsTag: Equatable {
    enum Style {
        case neutral
        case positive
        case warning
    }

    let title: String
    let style: Style
}

final class RoomDetailsNode: ScreenNode {

    var onAvatarTapped: (() -> Void)?
    var onRemoveAvatarTapped: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onInviteTapped: (() -> Void)?
    var onMembersTapped: (() -> Void)?
    var onProfileTapped: (() -> Void)?
    var onPinnedMessagesTapped: (() -> Void)?
    var onStorylinesTapped: (() -> Void)?
    var onSecurityPrivacyTapped: (() -> Void)?
    var onRolesPermissionsTapped: (() -> Void)?
    var onLeaveTapped: (() -> Void)?

    /// Set by the VC after the bar is configured. Lets us put the bar
    /// first in the a11y tree — otherwise VO walks subview order and
    /// reaches the bar last (it's added on top, so it's last subview).
    weak var glassTopBar: GlassTopBar?
    weak var voicePlayerView: UIView?

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
    private var tags: [RoomDetailsTag] = []
    private var tagNodes: [RoomDetailsTagNode] = []

    private let membersQuickAction = RoomDetailsQuickActionNode()
    private let searchQuickAction = RoomDetailsQuickActionNode()
    private let inviteQuickAction = RoomDetailsQuickActionNode()
    private let pinnedQuickAction = RoomDetailsQuickActionNode()

    private let profileRow = ActionRowNode()
    private let pinnedMessagesRow = ActionRowNode()
    private let searchRow = ActionRowNode()
    private let storylinesRow = ActionRowNode()
    private let securityRow = ActionRowNode()
    private let rolesPermissionsRow = ActionRowNode()
    private let leaveRoomRow = ActionRowNode()

    // MARK: - State

    var topInset: CGFloat = 40
    var bottomInset: CGFloat = 16

    private var isEditing = false
    private var isDirectRoom = false
    private var isDirectProfileAvailable = false
    private var isLeavingRoom = false
    private var hasAvatar = false
    private var storylinesTrailingText: String?
    private var storylinesNeedsAttention = false
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
        avatarBackgroundNode.isAccessibilityElement = false
        avatarBackgroundNode.accessibilityElementsHidden = true
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        avatarImageNode.isOpaque = false
        avatarImageNode.isAccessibilityElement = false
        avatarImageNode.accessibilityElementsHidden = true
        avatarInitialsNode.isAccessibilityElement = false
        avatarInitialsNode.accessibilityElementsHidden = true

        avatarTapNode.backgroundColor = .clear
        avatarTapNode.onTap = { [weak self] in self?.onAvatarTapped?() }
        avatarTapNode.isAccessibilityElement = false
        avatarTapNode.accessibilityTraits = .button
        avatarTapNode.accessibilityLabel = "Change group avatar"

        editAvatarOverlayNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        editAvatarOverlayNode.isHidden = true
        editAvatarOverlayNode.isAccessibilityElement = false
        editAvatarOverlayNode.accessibilityElementsHidden = true
        editAvatarIconNode.image = UIImage(systemName: "camera.fill")
        editAvatarIconNode.imageModificationBlock = ASImageNodeTintColorModificationBlock(.white)
        editAvatarIconNode.contentMode = .scaleAspectFit
        editAvatarIconNode.isAccessibilityElement = false
        editAvatarIconNode.accessibilityElementsHidden = true

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

        nameNode.isAccessibilityElement = true
        nameNode.accessibilityTraits = .header
        nameEditNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 22, weight: .bold),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.label
        ]
        nameEditNode.textContainerInset = .zero
        nameEditNode.accessibilityLabel = String(localized: "Group Name")

        membersQuickAction.onTap = { [weak self] in self?.onMembersTapped?() }
        membersQuickAction.apply(RoomDetailsQuickActionNode.Configuration(
            title: String(localized: "Members"),
            icon: AppIcon.person2.rendered(size: 20, weight: .semibold, color: AppColor.accent),
            accessibilityHint: String(localized: "Opens the member list")
        ))

        searchQuickAction.onTap = { [weak self] in self?.onSearchTapped?() }
        searchQuickAction.apply(RoomDetailsQuickActionNode.Configuration(
            title: String(localized: "Search"),
            icon: AppIcon.magnifyingGlass.rendered(size: 20, weight: .semibold, color: AppColor.accent),
            accessibilityLabel: String(localized: "Search Messages")
        ))

        inviteQuickAction.onTap = { [weak self] in self?.onInviteTapped?() }
        inviteQuickAction.apply(RoomDetailsQuickActionNode.Configuration(
            title: String(localized: "Invite"),
            icon: AppIcon.personBadgePlus.rendered(size: 20, weight: .semibold, color: AppColor.accent),
            accessibilityLabel: String(localized: "Invite Members")
        ))

        pinnedQuickAction.onTap = { [weak self] in self?.onPinnedMessagesTapped?() }
        pinnedQuickAction.apply(RoomDetailsQuickActionNode.Configuration(
            title: String(localized: "Pinned"),
            subtitle: "0",
            icon: AppIcon.pin.rendered(size: 20, weight: .semibold, color: AppColor.accent),
            accessibilityLabel: String(localized: "Pinned Messages"),
            accessibilityHint: String(localized: "Opens pinned messages")
        ))

        profileRow.onTap = { [weak self] in self?.onProfileTapped?() }
        profileRow.style.alignSelf = .stretch
        applyProfileRowConfiguration()

        pinnedMessagesRow.onTap = { [weak self] in self?.onPinnedMessagesTapped?() }
        pinnedMessagesRow.style.alignSelf = .stretch
        pinnedMessagesRow.apply(ActionRowNode.Configuration(
            title: String(localized: "Pinned Messages"),
            leadingIcon: AppIcon.pin.rendered(size: 17, weight: .medium, color: AppColor.accent),
            trailingText: "0",
            accessibilityHint: String(localized: "Opens pinned messages")
        ))

        searchRow.onTap = { [weak self] in self?.onSearchTapped?() }
        searchRow.style.alignSelf = .stretch
        searchRow.apply(ActionRowNode.Configuration(
            title: String(localized: "Search Messages"),
            leadingIcon: AppIcon.magnifyingGlass.rendered(size: 16, weight: .medium, color: AppColor.accent),
            accessibilityHint: String(localized: "Searches messages in this room")
        ))

        storylinesRow.onTap = { [weak self] in self?.onStorylinesTapped?() }
        storylinesRow.style.alignSelf = .stretch
        applyStorylinesRowConfiguration()

        securityRow.onTap = { [weak self] in self?.onSecurityPrivacyTapped?() }
        securityRow.style.alignSelf = .stretch
        securityRow.apply(ActionRowNode.Configuration(
            title: String(localized: "Security and Privacy"),
            leadingIcon: AppIcon.lockClosed.rendered(size: 16, weight: .medium, color: AppColor.accent),
            accessibilityHint: String(localized: "Opens room security and privacy settings")
        ))

        rolesPermissionsRow.onTap = { [weak self] in self?.onRolesPermissionsTapped?() }
        rolesPermissionsRow.style.alignSelf = .stretch
        rolesPermissionsRow.apply(ActionRowNode.Configuration(
            title: String(localized: "Roles and Permissions"),
            leadingIcon: AppIcon.person2.rendered(size: 16, weight: .medium, color: AppColor.accent),
            accessibilityHint: String(localized: "Opens room roles and permissions settings")
        ))

        leaveRoomRow.onTap = { [weak self] in self?.onLeaveTapped?() }
        leaveRoomRow.style.alignSelf = .stretch
        applyLeaveRoomRowConfiguration()
    }

    // MARK: - Update

    func update(
        name: String,
        memberCount: Int?,
        avatarMxcUrl: String?,
        fallbackUserId: String? = nil
    ) {
        hasAvatar = avatarMxcUrl != nil
        avatarLoadRevision &+= 1
        let loadRevision = avatarLoadRevision
        applyName(name, fallbackUserId: fallbackUserId)

        let membersSubtitle = memberCount.map { "\($0)" }
        let membersAccessibilityLabel = memberCount.map {
            String(localized: "\($0) members")
        } ?? String(localized: "Members")
        membersQuickAction.apply(RoomDetailsQuickActionNode.Configuration(
            title: String(localized: "Members"),
            subtitle: membersSubtitle,
            icon: AppIcon.person2.rendered(size: 20, weight: .semibold, color: AppColor.accent),
            accessibilityLabel: membersAccessibilityLabel,
            accessibilityHint: String(localized: "Opens the member list")
        ))

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
        applyName(name, fallbackUserId: nil)
        setNeedsLayout()
    }

    func updateTags(_ tags: [RoomDetailsTag]) {
        guard self.tags != tags else { return }
        self.tags = tags
        tagNodes = tags.map { RoomDetailsTagNode(tag: $0) }
        setNeedsLayout()
    }

    func updatePinnedMessagesCount(_ count: Int) {
        pinnedMessagesRow.updateTrailingText("\(count)")
        pinnedQuickAction.updateSubtitle("\(count)")
        setNeedsLayout()
    }

    func updateSpaceMembershipSummary(_ summary: RoomSpaceMembershipSummary?) {
        if let summary {
            if summary.count == 0 {
                storylinesTrailingText = String(localized: "None")
            } else {
                storylinesTrailingText = "\(summary.count)"
            }
            storylinesNeedsAttention = summary.attentionCount > 0
        } else {
            storylinesTrailingText = nil
            storylinesNeedsAttention = false
        }
        applyStorylinesRowConfiguration()
        setNeedsLayout()
    }

    func setDirectRoom(_ isDirectRoom: Bool) {
        guard self.isDirectRoom != isDirectRoom else { return }
        self.isDirectRoom = isDirectRoom
        applyLeaveRoomRowConfiguration()
        setNeedsLayout()
    }

    func setDirectProfileAvailable(_ available: Bool) {
        guard isDirectProfileAvailable != available else { return }
        isDirectProfileAvailable = available
        applyProfileRowConfiguration()
    }

    func setEditing(_ editing: Bool) {
        let effectiveEditing = editing && !isDirectRoom
        isEditing = effectiveEditing
        editAvatarOverlayNode.isHidden = !effectiveEditing
        avatarTapNode.isAccessibilityElement = effectiveEditing
        removeAvatarButtonNode.isHidden = !(effectiveEditing && hasAvatar)
        applyLeaveRoomRowConfiguration()
        setNeedsLayout()
    }

    func setLeavingRoom(_ leaving: Bool) {
        guard isLeavingRoom != leaving else { return }
        isLeavingRoom = leaving
        applyLeaveRoomRowConfiguration()
        setNeedsLayout()
    }

    private func applyName(_ name: String, fallbackUserId: String?) {
        if let fallbackUserId {
            let colorOverrideHex = ProfileAppearanceService.shared
                .cachedAppearance(userId: fallbackUserId)?
                .nameColorHex
            avatarBackgroundNode.backgroundColor = AvatarViewModel(
                userId: fallbackUserId,
                displayName: name,
                mxcAvatarURL: nil,
                colorOverrideHex: colorOverrideHex
            ).color
        } else {
            avatarBackgroundNode.backgroundColor = .systemGray4
        }

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
        nameNode.accessibilityLabel = name
        nameEditNode.attributedText = NSAttributedString(string: name, attributes: attrs)
    }

    private func applyProfileRowConfiguration() {
        profileRow.apply(ActionRowNode.Configuration(
            title: String(localized: "Profile"),
            leadingIcon: AppIcon.person.rendered(size: 17, weight: .medium, color: AppColor.accent),
            isEnabled: isDirectProfileAvailable,
            accessibilityHint: isDirectProfileAvailable ? String(localized: "Open Profile") : nil
        ))
    }

    private func applyStorylinesRowConfiguration() {
        storylinesRow.apply(ActionRowNode.Configuration(
            title: String(localized: "Storylines"),
            leadingIcon: AppIcon.link.rendered(
                size: 17,
                weight: .medium,
                color: storylinesNeedsAttention ? .systemOrange : AppColor.accent
            ),
            trailingText: storylinesTrailingText,
            accessibilityHint: String(localized: "Opens Storyline links")
        ))
    }

    private func applyLeaveRoomRowConfiguration() {
        let baseTitle = isDirectRoom
            ? String(localized: "Leave Conversation")
            : String(localized: "Leave Room")
        let leavingTitle = isDirectRoom
            ? String(localized: "Leaving Conversation")
            : String(localized: "Leaving Room")
        let title = isLeavingRoom ? leavingTitle : baseTitle
        let isEnabled = !isLeavingRoom && !isEditing

        leaveRoomRow.apply(ActionRowNode.Configuration(
            title: title,
            leadingIcon: AppIcon.personBadgeMinus.rendered(
                size: 17,
                weight: .medium,
                color: AppColor.destructive
            ),
            accessory: .none,
            isEnabled: isEnabled,
            titleColor: AppColor.destructive,
            accessibilityLabel: title,
            accessibilityHint: isEnabled
                ? String(localized: "Shows a confirmation before leaving")
                : nil
        ))
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

        var profileChildren: [ASLayoutElement] = [avatarSpec, nameSpec]
        if !tagNodes.isEmpty {
            let tagsSpec = ASStackLayoutSpec(
                direction: .horizontal,
                spacing: 6,
                justifyContent: .center,
                alignItems: .center,
                flexWrap: .wrap,
                alignContent: .center,
                lineSpacing: 6,
                children: tagNodes
            )
            tagsSpec.style.maxWidth = ASDimension(
                unit: .points,
                value: max(0, constrainedSize.max.width - 48)
            )
            profileChildren.append(tagsSpec)
        }

        let profileStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 8,
            justifyContent: .start, alignItems: .center,
            children: profileChildren
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        var buttonsChildren: [ASLayoutElement]
        if isDirectRoom {
            buttonsChildren = [
                profileRow,
                pinnedMessagesRow,
                searchRow,
                leaveRoomRow
            ]
        } else {
            buttonsChildren = [
                storylinesRow,
                securityRow,
                rolesPermissionsRow
            ]
        }

        let buttonsStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 12,
            justifyContent: .start, alignItems: .stretch,
            children: buttonsChildren
        )

        let mainChildren: [ASLayoutElement]
        if isDirectRoom {
            mainChildren = [profileStack, spacer, buttonsStack]
        } else {
            let quickActions = makeGroupQuickActionsGrid(
                availableWidth: max(0, constrainedSize.max.width - 48)
            )
            mainChildren = [profileStack, quickActions, buttonsStack, spacer, leaveRoomRow]
        }

        let mainStack = ASStackLayoutSpec(
            direction: .vertical, spacing: isDirectRoom ? 0 : 22,
            justifyContent: .start, alignItems: .stretch,
            children: mainChildren
        )

        let inset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 24, bottom: bottomInset, right: 24),
            child: mainStack
        )
        return ASBackgroundLayoutSpec(child: inset, background: contentNode)
    }

    private func makeGroupQuickActionsGrid(availableWidth: CGFloat) -> ASLayoutSpec {
        let spacing: CGFloat = 10
        let width = availableWidth.isFinite && availableWidth > 0
            ? availableWidth
            : max(0, ScreenConstants.width - 48)
        let cellWidth = floor((width - spacing) / 2)
        let cellSize = CGSize(width: cellWidth, height: 82)
        let actions: [RoomDetailsQuickActionNode] = [
            membersQuickAction,
            searchQuickAction,
            inviteQuickAction,
            pinnedQuickAction
        ]
        actions.forEach { $0.style.preferredSize = cellSize }

        let firstRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: spacing,
            justifyContent: .start,
            alignItems: .stretch,
            children: [membersQuickAction, searchQuickAction]
        )
        let secondRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: spacing,
            justifyContent: .start,
            alignItems: .stretch,
            children: [inviteQuickAction, pinnedQuickAction]
        )
        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: spacing,
            justifyContent: .start,
            alignItems: .stretch,
            children: [firstRow, secondRow]
        )
    }

    // MARK: - Actions

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

    }

    // MARK: - Accessibility

    /// Bar before content. Default subview-walk would put the bar last
    /// (it's the topmost subview), so VO swipe order would reach it
    /// only after stepping through avatar/name/actions.
    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            appendVisibleView(voicePlayerView, to: &elements)
            if let bar = glassTopBar, bar.view.superview === view {
                elements.append(contentsOf: bar.accessibilityElementsInOrder)
            }
            appendContentAccessibilityElements(to: &elements)
            return elements
        }
        set { }
    }

    private func appendContentAccessibilityElements(to elements: inout [Any]) {
        if isEditing {
            appendNodeView(avatarTapNode, to: &elements)
            appendNodeView(removeAvatarButtonNode, to: &elements)
            appendNodeView(nameEditNode, to: &elements)
        } else {
            appendNodeView(nameNode, to: &elements)
        }

        tagNodes.forEach { appendNodeView($0, to: &elements) }

        if isDirectRoom {
            appendActionRow(profileRow, to: &elements)
            appendActionRow(pinnedMessagesRow, to: &elements)
            appendActionRow(searchRow, to: &elements)
            appendActionRow(leaveRoomRow, to: &elements)
        } else {
            appendQuickAction(membersQuickAction, to: &elements)
            appendQuickAction(searchQuickAction, to: &elements)
            appendQuickAction(inviteQuickAction, to: &elements)
            appendQuickAction(pinnedQuickAction, to: &elements)
            appendActionRow(storylinesRow, to: &elements)
            appendActionRow(securityRow, to: &elements)
            appendActionRow(rolesPermissionsRow, to: &elements)
            appendActionRow(leaveRoomRow, to: &elements)
        }
    }

    private func appendNodeView(_ node: ASDisplayNode, to elements: inout [Any]) {
        guard node.isNodeLoaded else { return }
        appendVisibleView(node.view, to: &elements)
    }

    private func appendQuickAction(_ action: RoomDetailsQuickActionNode, to elements: inout [Any]) {
        appendVisibleView(action.accessibilityElementView, to: &elements)
    }

    private func appendActionRow(_ row: ActionRowNode, to elements: inout [Any]) {
        appendVisibleView(row.accessibilityElementView, to: &elements)
    }

    private func appendVisibleView(_ target: UIView?, to elements: inout [Any]) {
        guard let target,
              target.superview != nil,
              !target.isHidden,
              target.alpha > 0.01 else {
            return
        }
        elements.append(target)
    }
}

private final class RoomDetailsQuickActionNode: ASDisplayNode {

    struct Configuration {
        var title: String
        var subtitle: String?
        var icon: UIImage?
        var isEnabled: Bool
        var accessibilityLabel: String?
        var accessibilityHint: String?

        init(
            title: String,
            subtitle: String? = nil,
            icon: UIImage? = nil,
            isEnabled: Bool = true,
            accessibilityLabel: String? = nil,
            accessibilityHint: String? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.isEnabled = isEnabled
            self.accessibilityLabel = accessibilityLabel
            self.accessibilityHint = accessibilityHint
        }
    }

    var onTap: (() -> Void)?

    private let backgroundNode = RoundedBackgroundNode()
    private let tapNode = TappableNode()
    private let iconNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()

    private var configuration = Configuration(title: "")

    var accessibilityElementView: UIView? {
        guard isNodeLoaded, tapNode.isNodeLoaded else { return nil }
        return tapNode.view
    }

    override init() {
        super.init()
        automaticallyManagesSubnodes = true

        isAccessibilityElement = false
        accessibilityElementsHidden = false
        backgroundNode.isAccessibilityElement = false
        backgroundNode.accessibilityElementsHidden = true
        backgroundNode.fillColor = .secondarySystemBackground
        backgroundNode.radius = 12

        tapNode.backgroundColor = .clear
        tapNode.onTap = { [weak self] in
            guard let self, self.configuration.isEnabled else { return }
            self.onTap?()
        }

        iconNode.isAccessibilityElement = false
        iconNode.accessibilityElementsHidden = true
        iconNode.contentMode = .center
        iconNode.style.preferredSize = CGSize(width: 24, height: 24)

        titleNode.isAccessibilityElement = false
        titleNode.accessibilityElementsHidden = true
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail
        titleNode.style.flexShrink = 1

        subtitleNode.isAccessibilityElement = false
        subtitleNode.accessibilityElementsHidden = true
        subtitleNode.maximumNumberOfLines = 1
        subtitleNode.truncationMode = .byTruncatingTail
    }

    func apply(_ configuration: Configuration) {
        self.configuration = configuration

        iconNode.image = configuration.icon

        titleNode.attributedText = NSAttributedString(
            string: configuration.title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: configuration.isEnabled
                    ? UIColor.label
                    : UIColor.secondaryLabel
            ]
        )

        if let subtitle = configuration.subtitle, !subtitle.isEmpty {
            subtitleNode.attributedText = NSAttributedString(
                string: subtitle,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        } else {
            subtitleNode.attributedText = nil
        }

        let alpha: CGFloat = configuration.isEnabled ? 1 : 0.45
        iconNode.alpha = alpha
        titleNode.alpha = alpha
        subtitleNode.alpha = alpha

        tapNode.isAccessibilityElement = true
        tapNode.accessibilityElementsHidden = false
        tapNode.accessibilityTraits = configuration.isEnabled ? .button : .staticText
        tapNode.accessibilityLabel = configuration.accessibilityLabel ?? configuration.title
        tapNode.accessibilityValue = configuration.subtitle
        tapNode.accessibilityHint = configuration.isEnabled ? configuration.accessibilityHint : nil

        setNeedsLayout()
    }

    override var accessibilityElements: [Any]? {
        get {
            guard let accessibilityElementView else { return [] }
            return [accessibilityElementView]
        }
        set { }
    }

    func updateSubtitle(_ subtitle: String?) {
        var next = configuration
        next.subtitle = subtitle
        apply(next)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        var children: [ASLayoutElement] = []
        if configuration.icon != nil {
            children.append(iconNode)
        }
        children.append(titleNode)
        if configuration.subtitle?.isEmpty == false {
            children.append(subtitleNode)
        }

        let content = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 4,
            justifyContent: .center,
            alignItems: .center,
            children: children
        )
        let padded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8),
            child: content
        )
        let withBackground = ASBackgroundLayoutSpec(child: padded, background: backgroundNode)
        return ASOverlayLayoutSpec(child: withBackground, overlay: tapNode)
    }
}

private final class RoomDetailsTagNode: ASDisplayNode {

    private let textNode = ASTextNode()
    private let backgroundNode = RoundedBackgroundNode()

    init(tag: RoomDetailsTag) {
        super.init()
        automaticallyManagesSubnodes = true

        let colors = Self.colors(for: tag.style)
        backgroundNode.fillColor = colors.background
        backgroundNode.radius = 11

        textNode.attributedText = NSAttributedString(
            string: tag.title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: colors.foreground
            ]
        )
        textNode.maximumNumberOfLines = 1
        textNode.truncationMode = .byTruncatingTail

        isAccessibilityElement = true
        accessibilityLabel = tag.title
        accessibilityTraits = .staticText
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let padded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8),
            child: textNode
        )
        return ASBackgroundLayoutSpec(child: padded, background: backgroundNode)
    }

    private static func colors(for style: RoomDetailsTag.Style) -> (foreground: UIColor, background: UIColor) {
        switch style {
        case .neutral:
            return (.secondaryLabel, .secondarySystemBackground)
        case .positive:
            return (.systemGreen, UIColor.systemGreen.withAlphaComponent(0.14))
        case .warning:
            return (.systemOrange, UIColor.systemOrange.withAlphaComponent(0.16))
        }
    }
}
