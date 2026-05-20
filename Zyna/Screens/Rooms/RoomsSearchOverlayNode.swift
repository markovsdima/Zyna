//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class RoomsSearchOverlayNode: ASDisplayNode {

    let tableNode = ASTableNode()

    var onQueryChanged: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private weak var headerView: RoomsSearchHeaderView?

    private lazy var headerNode = ASDisplayNode(viewBlock: { [weak self] in
        let view = RoomsSearchHeaderView()
        view.onQueryChanged = { [weak self] query in
            self?.onQueryChanged?(query)
        }
        view.onCancel = { [weak self] in
            self?.onCancel?()
        }
        self?.headerView = view
        return view
    })

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .systemBackground
        tableNode.backgroundColor = .systemBackground
        tableNode.style.flexGrow = 1
        tableNode.style.flexShrink = 1
        headerNode.style.height = ASDimension(unit: .points, value: 72)
    }

    func focusSearch() {
        headerView?.focus()
    }

    func resetSearch() {
        headerView?.reset()
    }

    func endSearchEditing() {
        headerView?.endEditing(true)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [headerNode, tableNode]
        )
    }
}

private final class RoomsSearchHeaderView: UIView {

    var onQueryChanged: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let searchContainer = UIView()
    private let iconView = UIImageView()
    private let textField = UITextField()
    private let cancelButton = UIButton(type: .system)

    private let hPad: CGFloat = 16
    private let searchHeight: CGFloat = 38
    private let buttonSize: CGFloat = 36
    private let gap: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        searchContainer.backgroundColor = .secondarySystemBackground
        searchContainer.layer.cornerRadius = 10
        searchContainer.layer.cornerCurve = .continuous

        iconView.image = AppIcon.magnifyingGlass.template(size: 14, weight: .medium)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .center

        textField.placeholder = String(localized: "Search")
        textField.font = .systemFont(ofSize: 16)
        textField.returnKeyType = .search
        textField.clearButtonMode = .whileEditing
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        textField.addTarget(self, action: #selector(searchSubmitted), for: .editingDidEndOnExit)

        cancelButton.setImage(AppIcon.xmark.template(size: 15, weight: .semibold), for: .normal)
        cancelButton.tintColor = .secondaryLabel
        cancelButton.accessibilityLabel = String(localized: "Close Search")
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        addSubview(searchContainer)
        addSubview(cancelButton)
        searchContainer.addSubview(iconView)
        searchContainer.addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()

        let y = max(18, floor((bounds.height - searchHeight) / 2))
        let buttonX = bounds.width - hPad - buttonSize
        cancelButton.frame = CGRect(
            x: buttonX,
            y: y + (searchHeight - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )

        searchContainer.frame = CGRect(
            x: hPad,
            y: y,
            width: max(0, buttonX - gap - hPad),
            height: searchHeight
        )

        iconView.frame = CGRect(x: 8, y: 0, width: 28, height: searchHeight)
        textField.frame = CGRect(
            x: iconView.frame.maxX,
            y: 0,
            width: max(0, searchContainer.bounds.width - iconView.frame.maxX - 8),
            height: searchHeight
        )
    }

    func focus() {
        textField.becomeFirstResponder()
    }

    func reset() {
        textField.text = nil
        textField.resignFirstResponder()
    }

    @objc private func textChanged() {
        onQueryChanged?(textField.text ?? "")
    }

    @objc private func searchSubmitted() {
        textField.resignFirstResponder()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}

final class RoomsSearchHeaderCellNode: ZynaCellNode {
    private let titleNode = ASTextNode()

    init(title: String) {
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none
        titleNode.attributedText = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        titleNode.maximumNumberOfLines = 1
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 14, left: 16, bottom: 6, right: 16),
            child: titleNode
        )
    }
}

final class RoomsSearchStatusCellNode: ZynaCellNode {
    private let textNode = ASTextNode()

    init(text: String) {
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none
        textNode.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        textNode.maximumNumberOfLines = 2
        textNode.truncationMode = .byTruncatingTail
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let center = ASCenterLayoutSpec(
            centeringOptions: .X,
            sizingOptions: .minimumY,
            child: textNode
        )
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 28, left: 24, bottom: 28, right: 24),
            child: center
        )
    }
}

final class RoomsSearchResultCellNode: ZynaCellNode {

    private static let avatarDiameter: CGFloat = 44
    private static let avatarThumbSize = Int(avatarDiameter * ScreenConstants.scale)

    private let avatar: AvatarViewModel
    private let title: String
    private let subtitle: String
    private let accessory: String?

    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let accessoryNode = ASTextNode()
    private let separatorNode = ASDisplayNode()

    init(
        avatar: AvatarViewModel,
        title: String,
        subtitle: String,
        accessory: String? = nil
    ) {
        self.avatar = avatar
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
        setupAccessibility()
    }

    convenience init(user: UserProfile) {
        let displayName = user.displayName ?? user.userId
        self.init(
            avatar: AvatarViewModel(
                userId: user.userId,
                displayName: displayName,
                mxcAvatarURL: user.avatarUrl,
                colorOverrideHex: nil
            ),
            title: displayName,
            subtitle: user.userId
        )
    }

    convenience init(publicRoom: PublicRoomSearchResult) {
        let subtitle = publicRoom.alias ?? publicRoom.topic ?? publicRoom.roomId
        let accessory = publicRoom.joinedMembers > 0
            ? String(localized: "\(publicRoom.joinedMembers) members")
            : nil
        self.init(
            avatar: AvatarViewModel(
                userId: publicRoom.alias ?? publicRoom.roomId,
                displayName: publicRoom.name,
                mxcAvatarURL: publicRoom.avatarURL,
                colorOverrideHex: nil
            ),
            title: publicRoom.name,
            subtitle: subtitle,
            accessory: accessory
        )
    }

    private func setupNodes() {
        avatarBackgroundNode.image = avatar.circleImage(
            diameter: Self.avatarDiameter,
            fontSize: 16
        )
        avatarBackgroundNode.isLayerBacked = true

        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        avatarImageNode.isOpaque = false

        if let mxc = avatar.mxcAvatarURL {
            if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: Self.avatarThumbSize) {
                avatarImageNode.image = CircularImageCache.roundedImage(
                    source: cached,
                    diameter: Self.avatarDiameter,
                    cacheKey: mxc
                )
            } else {
                loadAvatarImage()
            }
        }

        titleNode.attributedText = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: UIColor.label
            ]
        )
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail

        subtitleNode.attributedText = NSAttributedString(
            string: subtitle,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        subtitleNode.maximumNumberOfLines = 1
        subtitleNode.truncationMode = .byTruncatingTail

        if let accessory {
            accessoryNode.attributedText = NSAttributedString(
                string: accessory,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: UIColor.tertiaryLabel
                ]
            )
            accessoryNode.maximumNumberOfLines = 1
        }

        separatorNode.backgroundColor = .separator
        separatorNode.style.height = ASDimension(unit: .points, value: 0.5)
    }

    private func loadAvatarImage() {
        guard let mxc = avatar.mxcAvatarURL else { return }
        let size = Self.avatarThumbSize
        Task { [weak self] in
            guard let source = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) else {
                return
            }
            let rounded = CircularImageCache.roundedImage(
                source: source,
                diameter: Self.avatarDiameter,
                cacheKey: mxc
            )
            await MainActor.run { [weak self] in
                self?.avatarImageNode.image = rounded
            }
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        avatarBackgroundNode.style.preferredSize = CGSize(
            width: Self.avatarDiameter,
            height: Self.avatarDiameter
        )
        avatarImageNode.style.preferredSize = CGSize(
            width: Self.avatarDiameter,
            height: Self.avatarDiameter
        )
        let avatarSpec = ASOverlayLayoutSpec(
            child: avatarBackgroundNode,
            overlay: avatarImageNode
        )

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .center,
            alignItems: .start,
            children: [titleNode, subtitleNode]
        )
        textStack.style.flexGrow = 1
        textStack.style.flexShrink = 1

        var rowChildren: [ASLayoutElement] = [avatarSpec, textStack]
        if accessory != nil {
            accessoryNode.style.flexShrink = 0
            rowChildren.append(accessoryNode)
        }

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: rowChildren
        )

        let content = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16),
            child: row
        )

        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [content, separatorNode]
        )
    }

    private func setupAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = [title, subtitle, accessory]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
