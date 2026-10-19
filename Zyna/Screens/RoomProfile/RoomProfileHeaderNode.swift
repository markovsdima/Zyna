// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

extension RoomProfileAction {
    var buttonTitle: String {
        switch self {
        case .invite: String(localized: "Add", table: "RoomProfile")
        case .notifications: String(localized: "Sound", table: "RoomProfile")
        default: title
        }
    }

    var title: String {
        switch self {
        case .call: String(localized: "Call", table: "RoomProfile")
        case .invite: String(localized: "Invite", table: "RoomProfile")
        case .search: String(localized: "Search")
        case .notifications: String(localized: "Notifications", table: "RoomProfile")
        case .more: String(localized: "More", table: "RoomProfile")
        case .members: String(localized: "Members")
        case .edit: String(localized: "Edit")
        case .information: String(localized: "Room Details")
        case .message: String(localized: "Chat")
        }
    }

    var icon: AppIcon {
        switch self {
        case .call: .phone
        case .invite: .personBadgePlus
        case .search: .magnifyingGlass
        case .notifications: .bell
        case .more: .ellipsis
        case .members: .person2
        case .edit: .pencil
        case .information: .settings
        case .message: .bubbleLeft
        }
    }
}

extension RoomNotificationSelection {
    var title: String {
        switch self {
        case .inherited: String(localized: "Use account settings", table: "RoomProfile")
        case .allMessages: String(localized: "All messages", table: "RoomProfile")
        case .mentions: String(localized: "Mentions and keywords", table: "RoomProfile")
        case .muted: String(localized: "Muted", table: "RoomProfile")
        }
    }
}

final class RoomProfileHeaderNode: ASDisplayNode {
    var onAction: ((RoomProfileAction) -> Void)?
    var onHeightChanged: (() -> Void)?
    private let titleNode = ASTextNode()
    private let subtitleNode = ASButtonNode()
    private let topicNode = ASTextNode()
    private let expandTopicNode = ASButtonNode()
    private let addressNode = ASTextNode()
    private var buttons: [RoomProfileActionNode] = []
    private var titleText: String
    private var subtitleText: String
    private var topic = ""
    private var address = ""
    private var showsMembers = false
    private var topicExpanded = false
    private var hasLongTopic: Bool { topic.count > 140 || topic.filter { $0 == "\n" }.count > 2 }

    init(title: String, subtitle: String) {
        titleText = title
        subtitleText = subtitle
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .appBG
        [titleNode, topicNode, addressNode].forEach { $0.isUserInteractionEnabled = false }
        titleNode.maximumNumberOfLines = 2
        titleNode.accessibilityTraits = .header
        subtitleNode.titleNode.maximumNumberOfLines = 2
        subtitleNode.isUserInteractionEnabled = false
        addressNode.maximumNumberOfLines = 2
        addressNode.truncationMode = .byTruncatingMiddle
        updateTypography()
    }

    override func didLoad() {
        super.didLoad()
        subtitleNode.addTarget(self, action: #selector(openMembers), forControlEvents: .touchUpInside)
        expandTopicNode.addTarget(self, action: #selector(toggleTopic), forControlEvents: .touchUpInside)
        subtitleNode.accessibilityIdentifier = "profile.members"
        expandTopicNode.accessibilityIdentifier = "profile.expandTopic"
    }

    /// Decorative areas pass through to the page's scroll and back gestures.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === view ? nil : hit
    }

    func apply(_ snapshot: RoomProfileSnapshot) {
        titleText = snapshot.title
        showsMembers = !snapshot.isDirect
        subtitleText = snapshot.isDirect ? (snapshot.directUserID ?? "")
            : snapshot.memberCount.map { String(localized: "\($0) members") } ?? String(localized: "Members")
        if topic != (snapshot.topic ?? "") { topicExpanded = false }
        topic = snapshot.topic ?? ""
        address = snapshot.isDirect ? "" : (snapshot.address ?? "")
        let actions = RoomProfileAction.primary(for: snapshot)
        applyActions(actions, enabled: { $0.isEnabled(in: snapshot) })
    }

    func apply(_ snapshot: PersonProfileSnapshot, canOpenChat: Bool, presence: String?) {
        titleText = snapshot.title
        showsMembers = false
        subtitleText = [snapshot.userID, presence].compactMap { $0 }.joined(separator: "\n")
        topic = snapshot.group.map { group in
            let membership: String
            switch group.membership {
            case .join: membership = group.role.localizedLabel
            case .invite: membership = String(localized: "Invited", table: "RoomProfile")
            case .ban: membership = String(localized: "Banned", table: "RoomProfile")
            default: membership = String(localized: "Not a member", table: "RoomProfile")
            }
            return "\(group.title)\n\(membership)"
        } ?? ""
        address = ""
        let actions: [RoomProfileAction] = snapshot.isSelf ? [.more] : [.message, .more]
        applyActions(actions, enabled: { $0 != .message || canOpenChat })
    }

    private func applyActions(_ actions: [RoomProfileAction], enabled: (RoomProfileAction) -> Bool) {
        subtitleNode.isUserInteractionEnabled = showsMembers
        subtitleNode.accessibilityTraits = showsMembers ? .button : .staticText
        if buttons.map(\.action) != actions {
            buttons = actions.map { action in
                let button = RoomProfileActionNode(action: action)
                button.onTap = { [weak self] in self?.onAction?(action) }
                return button
            }
        }
        for button in buttons { button.setEnabled(enabled(button.action)) }
        updateTypography()
    }

    func setMoreMenu(_ menu: UIMenu) { buttons.first { $0.action == .more }?.setMenu(menu) }

    func setMenus(more: UIMenu, notifications: UIMenu, notificationDetail: String, isMuted: Bool) {
        buttons.first { $0.action == .more }?.setMenu(more)
        if let button = buttons.first(where: { $0.action == .notifications }) {
            button.setMenu(notifications)
            button.setDetail(notificationDetail, icon: isMuted ? .bellSlash : .bell)
        }
    }

    func updateTypography() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        titleNode.attributedText = NSAttributedString(string: titleText, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .title2), .foregroundColor: UIColor.label,
            .paragraphStyle: centered
        ])
        subtitleNode.setAttributedTitle(NSAttributedString(string: subtitleText, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: showsMembers ? UIColor.systemBlue : UIColor.secondaryLabel,
            .paragraphStyle: centered
        ]), for: .normal)
        topicNode.attributedText = NSAttributedString(string: topic, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label
        ])
        topicNode.maximumNumberOfLines = topicExpanded || !hasLongTopic ? 0 : 3
        topicNode.truncationMode = .byTruncatingTail
        expandTopicNode.setTitle(topicExpanded ? String(localized: "Show less", table: "RoomProfile")
            : String(localized: "Read more", table: "RoomProfile"),
            with: .preferredFont(forTextStyle: .subheadline), with: .systemBlue, for: .normal)
        addressNode.attributedText = NSAttributedString(string: address, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: UIColor.secondaryLabel
        ])
        buttons.forEach { $0.updateTypography() }
        setNeedsLayout()
    }

    @objc private func openMembers() { if showsMembers { onAction?(.members) } }
    @objc private func toggleTopic() {
        topicExpanded.toggle()
        updateTypography()
        onHeightChanged?()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // The controller positions the photo independently while this slot
        // keeps the body measured once throughout circle-to-square expansion.
        let avatarSlot = ASLayoutSpec()
        avatarSlot.style.preferredSize = CGSize(width: RoomProfileAvatarGeometry.diameter,
            height: RoomProfileAvatarGeometry.diameter)
        let identity = ASStackLayoutSpec.vertical()
        identity.spacing = 8
        identity.alignItems = .center
        identity.children = [avatarSlot, titleNode, subtitleNode]
        let stack = ASStackLayoutSpec.vertical()
        stack.spacing = 16
        var children: [ASLayoutElement] = [identity]
        if !buttons.isEmpty {
            let row = ASStackLayoutSpec.horizontal()
            row.spacing = 8
            row.alignItems = .stretch
            let count = CGFloat(buttons.count)
            for button in buttons {
                button.style.width = ASDimension(unit: .points,
                    value: max(0, (constrainedSize.max.width - 32 - 8 * (count - 1)) / count))
            }
            row.children = buttons
            children.append(row)
        }
        if !topic.isEmpty {
            let description = ASStackLayoutSpec.vertical()
            description.spacing = 4
            description.alignItems = .start
            description.children = hasLongTopic ? [topicNode, expandTopicNode] : [topicNode]
            children.append(description)
        }
        if !address.isEmpty { children.append(addressNode) }
        stack.children = children
        return ASInsetLayoutSpec(insets: UIEdgeInsets(top: RoomProfileAvatarGeometry.topInset,
            left: 16, bottom: 16, right: 16), child: stack)
    }
}

/// Texture draws the contents. A fixed UIButton host supplies tap menus and
/// accessibility; there are four hosts, independent of the media item count.
private final class RoomProfileActionNode: ASDisplayNode {
    let action: RoomProfileAction
    var onTap: (() -> Void)?
    private let imageNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let control = ASDisplayNode(viewBlock: { UIButton(type: .custom) })
    private var detail = ""
    private var icon: AppIcon
    private var menu: UIMenu?
    private var enabled = true

    init(action: RoomProfileAction) {
        self.action = action
        icon = action.icon
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .secondarySystemBackground
        cornerRadius = 14
        imageNode.style.preferredSize = CGSize(width: 24, height: 24)
        imageNode.contentMode = .center
        titleNode.maximumNumberOfLines = 2
        titleNode.truncationMode = .byTruncatingTail
        [imageNode, titleNode].forEach {
            $0.isUserInteractionEnabled = false
            $0.isAccessibilityElement = false
        }
        updateTypography()
    }

    override func didLoad() {
        super.didLoad()
        let button = control.view as! UIButton
        button.accessibilityIdentifier = "profile.action.\(action.rawValue)"
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        button.addTarget(self, action: #selector(highlight), for: .touchDown)
        button.addTarget(self, action: #selector(unhighlight), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        updateControl()
        updateIcon()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        alpha = enabled ? 1 : 0.4
        updateControl()
    }

    func setMenu(_ menu: UIMenu) { self.menu = menu; updateControl() }

    func setDetail(_ detail: String, icon: AppIcon) {
        guard self.detail != detail || self.icon != icon else { return }
        self.detail = detail
        self.icon = icon
        if isNodeLoaded { updateIcon() }
        updateControl()
    }

    func updateTypography() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        titleNode.attributedText = NSAttributedString(string: action.buttonTitle, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: UIColor.label,
            .paragraphStyle: centered
        ])
        setNeedsLayout()
    }

    private func updateIcon() { imageNode.image = icon.rendered(size: 20, color: .systemBlue) }
    private func updateControl() {
        guard control.isNodeLoaded, let button = control.view as? UIButton else { return }
        button.menu = menu
        button.showsMenuAsPrimaryAction = menu != nil
        button.isEnabled = enabled
        button.accessibilityLabel = action.title
        button.accessibilityValue = detail.isEmpty ? nil : detail
    }

    @objc private func tapped() { if enabled && menu == nil { onTap?() } }
    @objc private func highlight() { if menu == nil { alpha = 0.55 } }
    @objc private func unhighlight() { alpha = enabled ? 1 : 0.4 }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let stack = ASStackLayoutSpec.vertical()
        stack.spacing = 4
        stack.alignItems = .center
        stack.justifyContent = .start
        stack.children = [imageNode, titleNode]
        let padded = ASInsetLayoutSpec(insets: UIEdgeInsets(top: 12, left: 3, bottom: 12, right: 3), child: stack)
        return ASOverlayLayoutSpec(child: padded, overlay: control)
    }
}
