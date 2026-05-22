//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

enum CreateRoomPresentation {
    case groupRoom
    case spaceChildChat

    var screenTitle: String {
        switch self {
        case .groupRoom:
            return String(localized: "New Group")
        case .spaceChildChat:
            return String(localized: "New Chat")
        }
    }

    var nameLabel: String {
        switch self {
        case .groupRoom:
            return String(localized: "Group Name")
        case .spaceChildChat:
            return String(localized: "Chat Name")
        }
    }

    var createButtonTitle: String {
        switch self {
        case .groupRoom:
            return String(localized: "Create Group")
        case .spaceChildChat:
            return String(localized: "Create Chat")
        }
    }
}

final class CreateGroupNode: ScreenNode {

    let nameInputNode = ASEditableTextNode()
    let topicInputNode = ASEditableTextNode()
    let aliasInputNode = ASEditableTextNode()
    let membersLabel = ASTextNode()
    let membersCountNode = ASTextNode()
    let createButtonNode = ASButtonNode()

    var onPostingPermissionSelected: ((CreateGroupPostingPermission) -> Void)?
    var onRoomAccessSelected: ((CreateGroupAccess) -> Void)?

    private let nameLabel = ASTextNode()
    private let topicLabel = ASTextNode()
    private let postingPermissionLabel = ASTextNode()
    private let roomAccessLabel = ASTextNode()
    private let aliasLabel = ASTextNode()
    private let aliasPrefixNode = ASTextNode()
    private let aliasServerNode = ASTextNode()
    private let nameSeparator = ASDisplayNode()
    private let topicSeparator = ASDisplayNode()
    private let aliasSeparator = ASDisplayNode()

    private let allMembersOptionNode = CreateGroupOptionNode(
        icon: AppIcon.person2.template(size: 18, weight: .semibold),
        title: String(localized: "All Members"),
        subtitle: String(localized: "Members can send messages according to room permissions.")
    )
    private let moderatorsOnlyOptionNode = CreateGroupOptionNode(
        icon: AppIcon.megaphone.template(size: 18, weight: .semibold),
        title: String(localized: "Moderators Only"),
        subtitle: String(localized: "Regular members can read, but only moderators can post.")
    )
    private let privateOptionNode = CreateGroupOptionNode(
        icon: AppIcon.lockClosed.template(size: 18, weight: .semibold),
        title: String(localized: "Private"),
        subtitle: String(localized: "Only invited people can join. Messages are encrypted.")
    )
    private let publicOptionNode = CreateGroupOptionNode(
        icon: AppIcon.globe.template(size: 18, weight: .semibold),
        title: String(localized: "Public"),
        subtitle: String(localized: "Anyone can find and join. Messages are not encrypted.")
    )

    private var selectedPostingPermission: CreateGroupPostingPermission = .allMembers
    private var selectedAccess: CreateGroupAccess = .privateInviteOnly
    private var aliasServerName: String?
    private var isCreating = false
    private var membersCount = 0
    private let presentation: CreateRoomPresentation

    init(presentation: CreateRoomPresentation = .groupRoom) {
        self.presentation = presentation
        super.init()

        nameLabel.attributedText = NSAttributedString(
            string: presentation.nameLabel,
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )

        nameInputNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16)
        ]
        nameInputNode.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        nameInputNode.style.minHeight = ASDimension(unit: .points, value: 36)

        nameSeparator.backgroundColor = .separator
        nameSeparator.style.height = ASDimension(unit: .points, value: 0.5)

        topicLabel.attributedText = NSAttributedString(
            string: String(localized: "Topic (optional)"),
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )

        topicInputNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16)
        ]
        topicInputNode.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        topicInputNode.style.minHeight = ASDimension(unit: .points, value: 36)

        topicSeparator.backgroundColor = .separator
        topicSeparator.style.height = ASDimension(unit: .points, value: 0.5)

        postingPermissionLabel.attributedText = Self.sectionTitle(String(localized: "Posting Permissions"))
        roomAccessLabel.attributedText = Self.sectionTitle(String(localized: "Access"))
        aliasLabel.attributedText = Self.sectionTitle(String(localized: "Room Address"))
        aliasPrefixNode.attributedText = Self.aliasChrome("#")

        aliasInputNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.label
        ]
        aliasInputNode.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        aliasInputNode.style.minHeight = ASDimension(unit: .points, value: 36)
        aliasInputNode.style.flexGrow = 1
        aliasInputNode.style.flexShrink = 1

        aliasSeparator.backgroundColor = .separator
        aliasSeparator.style.height = ASDimension(unit: .points, value: 0.5)

        allMembersOptionNode.onTap = { [weak self] in self?.selectPostingPermission(.allMembers) }
        moderatorsOnlyOptionNode.onTap = { [weak self] in self?.selectPostingPermission(.moderatorsOnly) }
        privateOptionNode.onTap = { [weak self] in self?.selectAccess(.privateInviteOnly) }
        publicOptionNode.onTap = { [weak self] in self?.selectAccess(.publicAnyone) }
        applySelection()

        membersLabel.attributedText = NSAttributedString(
            string: String(localized: "Members"),
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )

        createButtonNode.setTitle(presentation.createButtonTitle, with: UIFont.systemFont(ofSize: 17, weight: .semibold), with: .white, for: .normal)
        createButtonNode.backgroundColor = .systemBlue
        createButtonNode.cornerRadius = 12
        createButtonNode.style.height = ASDimension(unit: .points, value: 50)
    }

    func updateSelection(postingPermission: CreateGroupPostingPermission, access: CreateGroupAccess) {
        selectedPostingPermission = postingPermission
        selectedAccess = access
        applySelection()
        setNeedsLayout()
    }

    func updateAliasLocalPart(_ localPart: String) {
        aliasInputNode.attributedText = NSAttributedString(
            string: localPart,
            attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label]
        )
    }

    func updateAliasServerName(_ serverName: String?) {
        aliasServerName = serverName
        let suffix = serverName.map { ":\($0)" } ?? ""
        aliasServerNode.attributedText = Self.aliasChrome(suffix)
        setNeedsLayout()
    }

    func updateCreating(_ isCreating: Bool) {
        self.isCreating = isCreating
        refreshCreateButton()
    }

    private func refreshCreateButton() {
        createButtonNode.isEnabled = !isCreating
        createButtonNode.alpha = isCreating ? 0.55 : 1
        let title = isCreating
            ? String(localized: "Creating...")
            : presentation.createButtonTitle
        createButtonNode.setTitle(title, with: UIFont.systemFont(ofSize: 17, weight: .semibold), with: .white, for: .normal)
    }

    func updateMembersCount(_ count: Int) {
        membersCount = count
        membersCountNode.attributedText = NSAttributedString(
            string: "\(count) member\(count == 1 ? "" : "s")",
            attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.label]
        )
        setNeedsLayout()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let nameSection = ASStackLayoutSpec(
            direction: .vertical, spacing: 4, justifyContent: .start, alignItems: .stretch,
            children: [nameLabel, nameInputNode, nameSeparator]
        )

        let topicSection = ASStackLayoutSpec(
            direction: .vertical, spacing: 4, justifyContent: .start, alignItems: .stretch,
            children: [topicLabel, topicInputNode, topicSeparator]
        )

        let postingOptions = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 8,
            justifyContent: .start,
            alignItems: .stretch,
            children: [allMembersOptionNode, moderatorsOnlyOptionNode]
        )
        let postingSection = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 8,
            justifyContent: .start,
            alignItems: .stretch,
            children: [postingPermissionLabel, postingOptions]
        )

        let accessOptions = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 8,
            justifyContent: .start,
            alignItems: .stretch,
            children: [privateOptionNode, publicOptionNode]
        )
        let accessSection = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 8,
            justifyContent: .start,
            alignItems: .stretch,
            children: [roomAccessLabel, accessOptions]
        )

        var configurationChildren: [ASLayoutElement] = [accessSection, postingSection]
        if selectedAccess.isPublic {
            configurationChildren.append(aliasSection())
        }
        let configurationSection = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 18,
            justifyContent: .start,
            alignItems: .stretch,
            children: configurationChildren
        )

        let membersSection = ASStackLayoutSpec(
            direction: .vertical, spacing: 4, justifyContent: .start, alignItems: .stretch,
            children: [membersLabel, membersCountNode]
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        var mainChildren: [ASLayoutElement] = [nameSection, topicSection, configurationSection]
        if membersCount > 0 {
            mainChildren.append(membersSection)
        }
        mainChildren.append(spacer)
        mainChildren.append(createButtonNode)

        let mainStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 24, justifyContent: .start, alignItems: .stretch,
            children: mainChildren
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16),
            child: mainStack
        )
    }

    private func selectPostingPermission(_ permission: CreateGroupPostingPermission) {
        guard !isCreating else { return }
        guard permission != selectedPostingPermission else { return }
        selectedPostingPermission = permission
        applySelection()
        onPostingPermissionSelected?(permission)
        setNeedsLayout()
    }

    private func selectAccess(_ access: CreateGroupAccess) {
        guard !isCreating else { return }
        guard access != selectedAccess else { return }
        selectedAccess = access
        applySelection()
        onRoomAccessSelected?(access)
        setNeedsLayout()
    }

    private func applySelection() {
        allMembersOptionNode.setSelected(selectedPostingPermission == .allMembers)
        moderatorsOnlyOptionNode.setSelected(selectedPostingPermission == .moderatorsOnly)
        privateOptionNode.setSelected(selectedAccess == .privateInviteOnly)
        publicOptionNode.setSelected(selectedAccess == .publicAnyone)
        refreshCreateButton()
    }

    private func aliasSection() -> ASLayoutSpec {
        let aliasRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 0,
            justifyContent: .start,
            alignItems: .center,
            children: [aliasPrefixNode, aliasInputNode, aliasServerNode]
        )

        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 4,
            justifyContent: .start,
            alignItems: .stretch,
            children: [aliasLabel, aliasRow, aliasSeparator]
        )
    }

    private static func sectionTitle(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )
    }

    private static func aliasChrome(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.secondaryLabel]
        )
    }
}

private final class CreateGroupOptionNode: TappableNode {

    private let backgroundNode = RoundedBackgroundNode()
    private let iconNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let checkmarkNode = ASImageNode()
    private let icon: UIImage
    private let title: String
    private let subtitle: String
    private var isOptionSelected = false

    init(icon: UIImage, title: String, subtitle: String) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
        setSelected(false)
    }

    func setSelected(_ selected: Bool) {
        isOptionSelected = selected

        backgroundNode.fillColor = selected
            ? UIColor.systemBlue.withAlphaComponent(0.10)
            : UIColor.secondarySystemBackground

        iconNode.image = icon
        iconNode.imageModificationBlock = ASImageNodeTintColorModificationBlock(selected ? .systemBlue : .secondaryLabel)
        let checkmarkIcon: AppIcon = selected ? .checkmarkCircleFill : .circle
        let checkmarkColor: UIColor = selected ? .systemBlue : .tertiaryLabel
        checkmarkNode.image = checkmarkIcon.rendered(size: 22, weight: .regular, color: checkmarkColor)

        titleNode.attributedText = NSAttributedString(
            string: title,
            attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.label]
        )
        subtitleNode.attributedText = NSAttributedString(
            string: subtitle,
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]
        )

        accessibilityTraits = selected ? [.button, .selected] : .button
        setNeedsLayout()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        iconNode.style.preferredSize = CGSize(width: 24, height: 24)
        checkmarkNode.style.preferredSize = CGSize(width: 22, height: 22)

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 3,
            justifyContent: .center,
            alignItems: .stretch,
            children: [titleNode, subtitleNode]
        )
        textStack.style.flexGrow = 1
        textStack.style.flexShrink = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: [iconNode, textStack, checkmarkNode]
        )

        let inset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
            child: row
        )
        return ASBackgroundLayoutSpec(child: inset, background: backgroundNode)
    }

    private func setupNodes() {
        backgroundNode.radius = 12
        iconNode.contentMode = .scaleAspectFit
        checkmarkNode.contentMode = .scaleAspectFit
        subtitleNode.maximumNumberOfLines = 0
        isAccessibilityElement = true
        accessibilityLabel = "\(title). \(subtitle)"
    }

}
