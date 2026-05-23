//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceCreationNode: ScreenNode {

    let backButtonNode = ASButtonNode()
    let nameInputNode = ASEditableTextNode()
    let topicInputNode = ASEditableTextNode()
    let aliasInputNode = ASEditableTextNode()
    let createButtonNode = ASButtonNode()

    var onAccessSelected: ((SpaceCreationAccess) -> Void)?

    var topInset: CGFloat = 0 {
        didSet {
            guard abs(topInset - oldValue) > 0.5 else { return }
            setNeedsLayout()
        }
    }

    private let mode: SpaceCreationMode
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let hintNode = ASTextNode()
    private let nameLabel = ASTextNode()
    private let topicLabel = ASTextNode()
    private let accessLabel = ASTextNode()
    private let aliasLabel = ASTextNode()
    private let aliasPrefixNode = ASTextNode()
    private let aliasServerNode = ASTextNode()
    private let nameSeparator = ASDisplayNode()
    private let topicSeparator = ASDisplayNode()
    private let aliasSeparator = ASDisplayNode()
    private let privateOptionNode = SpaceCreationOptionNode(
        icon: AppIcon.lockClosed.template(size: 18, weight: .semibold),
        title: String(localized: "Private"),
        subtitle: String(localized: "Only invited people can find and join.")
    )
    private let publicOptionNode = SpaceCreationOptionNode(
        icon: AppIcon.globe.template(size: 18, weight: .semibold),
        title: String(localized: "Public"),
        subtitle: String(localized: "Anyone can find and join.")
    )
    private var selectedAccess: SpaceCreationAccess = .privateInviteOnly
    private var isCreating = false

    init(mode: SpaceCreationMode) {
        self.mode = mode
        super.init()
        automaticallyManagesSubnodes = false
        backgroundColor = .systemBackground
        setupNodes()
        [
            backButtonNode,
            titleNode,
            subtitleNode,
            hintNode,
            nameLabel,
            nameInputNode,
            nameSeparator,
            topicLabel,
            topicInputNode,
            topicSeparator,
            accessLabel,
            privateOptionNode,
            publicOptionNode,
            aliasLabel,
            aliasPrefixNode,
            aliasInputNode,
            aliasServerNode,
            aliasSeparator,
            createButtonNode
        ].forEach(addSubnode)
    }

    func updateSelection(access: SpaceCreationAccess) {
        selectedAccess = access
        applyAccessSelection()
        setNeedsLayout()
    }

    func updateAliasLocalPart(_ localPart: String) {
        aliasInputNode.attributedText = NSAttributedString(
            string: localPart,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.label
            ]
        )
    }

    func updateAliasServerName(_ serverName: String?) {
        let suffix = serverName.map { ":\($0)" } ?? ""
        aliasServerNode.attributedText = Self.aliasChrome(suffix)
        setNeedsLayout()
    }

    func updateCreating(_ isCreating: Bool) {
        self.isCreating = isCreating
        refreshCreateButton()
    }

    private func setupNodes() {
        backButtonNode.setImage(
            AppIcon.chevronBackward.rendered(size: 17, weight: .semibold, color: .label),
            for: .normal
        )
        backButtonNode.style.preferredSize = CGSize(width: 44, height: 44)
        backButtonNode.accessibilityLabel = String(localized: "Back")

        titleNode.attributedText = NSAttributedString(
            string: mode.title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail

        subtitleNode.attributedText = NSAttributedString(
            string: mode.subtitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        subtitleNode.maximumNumberOfLines = 1
        subtitleNode.truncationMode = .byTruncatingTail

        hintNode.attributedText = NSAttributedString(
            string: mode.hint,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        hintNode.maximumNumberOfLines = 0

        nameLabel.attributedText = sectionTitle(mode.nameLabel)
        topicLabel.attributedText = sectionTitle(String(localized: "Description (optional)"))
        accessLabel.attributedText = sectionTitle(String(localized: "Access"))
        aliasLabel.attributedText = sectionTitle(mode.addressLabel)
        aliasPrefixNode.attributedText = Self.aliasChrome("#")

        setupInput(nameInputNode)
        setupInput(topicInputNode)
        setupInput(aliasInputNode)
        aliasInputNode.style.flexGrow = 1
        aliasInputNode.style.flexShrink = 1

        nameSeparator.backgroundColor = .separator
        topicSeparator.backgroundColor = .separator
        aliasSeparator.backgroundColor = .separator
        nameSeparator.style.height = ASDimension(unit: .points, value: 0.5)
        topicSeparator.style.height = ASDimension(unit: .points, value: 0.5)
        aliasSeparator.style.height = ASDimension(unit: .points, value: 0.5)

        privateOptionNode.onTap = { [weak self] in
            self?.selectAccess(.privateInviteOnly)
        }
        publicOptionNode.onTap = { [weak self] in
            self?.selectAccess(.publicAnyone)
        }
        applyAccessSelection()

        createButtonNode.backgroundColor = .systemBlue
        createButtonNode.cornerRadius = 12
        createButtonNode.style.height = ASDimension(unit: .points, value: 50)
        refreshCreateButton()
    }

    private func setupInput(_ node: ASEditableTextNode) {
        node.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.label
        ]
        node.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        node.style.minHeight = ASDimension(unit: .points, value: 36)
    }

    private func refreshCreateButton() {
        createButtonNode.isEnabled = !isCreating
        createButtonNode.alpha = isCreating ? 0.55 : 1
        let title = isCreating
            ? String(localized: "Creating...")
            : mode.createButtonTitle
        createButtonNode.setTitle(
            title,
            with: UIFont.systemFont(ofSize: 17, weight: .semibold),
            with: .white,
            for: .normal
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let titleStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 1,
            justifyContent: .center,
            alignItems: .center,
            children: [titleNode, subtitleNode]
        )
        titleStack.style.flexGrow = 1
        titleStack.style.flexShrink = 1

        let rightSpacer = ASLayoutSpec()
        rightSpacer.style.preferredSize = CGSize(width: 44, height: 44)

        let header = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 0,
            justifyContent: .start,
            alignItems: .center,
            children: [backButtonNode, titleStack, rightSpacer]
        )
        header.style.height = ASDimension(unit: .points, value: 44)

        let nameSection = inputSection(
            label: nameLabel,
            input: nameInputNode,
            separator: nameSeparator
        )
        let topicSection = inputSection(
            label: topicLabel,
            input: topicInputNode,
            separator: topicSeparator
        )
        let accessSection = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 8,
            justifyContent: .start,
            alignItems: .stretch,
            children: [
                accessLabel,
                ASStackLayoutSpec(
                    direction: .vertical,
                    spacing: 8,
                    justifyContent: .start,
                    alignItems: .stretch,
                    children: [privateOptionNode, publicOptionNode]
                )
            ]
        )

        var configurationChildren: [ASLayoutElement] = [accessSection]
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

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let form = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 24,
            justifyContent: .start,
            alignItems: .stretch,
            children: [hintNode, nameSection, topicSection, configurationSection, spacer, createButtonNode]
        )

        let formInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 20, left: 16, bottom: 24, right: 16),
            child: form
        )

        let root = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [header, formInset]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0),
            child: root
        )
    }

    private func inputSection(
        label: ASTextNode,
        input: ASEditableTextNode,
        separator: ASDisplayNode
    ) -> ASLayoutSpec {
        ASStackLayoutSpec(
            direction: .vertical,
            spacing: 4,
            justifyContent: .start,
            alignItems: .stretch,
            children: [label, input, separator]
        )
    }

    private func selectAccess(_ access: SpaceCreationAccess) {
        guard !isCreating else { return }
        guard access != selectedAccess else { return }
        selectedAccess = access
        applyAccessSelection()
        onAccessSelected?(access)
        setNeedsLayout()
    }

    private func applyAccessSelection() {
        privateOptionNode.setSelected(selectedAccess == .privateInviteOnly)
        publicOptionNode.setSelected(selectedAccess == .publicAnyone)
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

    private func sectionTitle(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    private static func aliasChrome(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = [
                backButtonNode.view,
                nameInputNode.view,
                topicInputNode.view,
                privateOptionNode.view,
                publicOptionNode.view
            ]
            if selectedAccess.isPublic {
                elements.append(aliasInputNode.view)
            }
            elements.append(createButtonNode.view)
            return elements
        }
        set { }
    }
}

private final class SpaceCreationOptionNode: TappableNode {

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
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        subtitleNode.attributedText = NSAttributedString(
            string: subtitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
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
