//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Orders `accessibilityElements` bar-before-content so VoiceOver reads the
/// glass bar first, regardless of subnode insertion order.
final class ProfileScreenNode: ScreenNode {

    let content: ProfileNode
    weak var glassTopBar: ASDisplayNode?

    init(mode: ProfileMode) {
        self.content = ProfileNode(mode: mode)
        super.init()
        automaticallyManagesSubnodes = false
        addSubnode(content)
    }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar?.view, bar.superview === view {
                elements.append(bar)
            }
            elements.append(content.view)
            return elements
        }
        set { }
    }
}

final class ProfileNode: ScreenNode {

    // MARK: - Callbacks

    var onAvatarTapped: (() -> Void)?
    var onLogoutTapped: (() -> Void)?
    var onSettingsTapped: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onMessageTapped: (() -> Void)?
    var messageButtonTitle: String? {
        didSet {
            guard let title = messageButtonTitle else { return }
            messageButtonNode.setAttributedTitle(NSAttributedString(
                string: title,
                attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: UIColor.white]
            ), for: .normal)
            setNeedsLayout()
        }
    }

    // MARK: - Nodes

    private let avatarBackgroundNode = ASDisplayNode()
    private let avatarImageNode = ASImageNode()
    private let avatarInitialsNode = ASTextNode()
    private let editAvatarOverlayNode = ASDisplayNode()
    private let editAvatarIconNode = ASImageNode()

    private let displayNameNode = ASTextNode()
    private let nameEditNode = ASEditableTextNode()
    private let userIdNode = ASTextNode()
    private let copyButtonNode = ASButtonNode()

    private let presenceNode = ASTextNode()

    private let messageButtonNode = ASButtonNode()
    private let searchButtonNode = ASButtonNode()
    private let settingsButtonNode = ASButtonNode()
    private let logoutButtonNode = ASButtonNode()

    // MARK: - State

    private let mode: ProfileMode
    private var isEditing = false

    var topInset: CGFloat = 40
    var bottomInset: CGFloat = 16

    var editingName: String? {
        nameEditNode.attributedText?.string
    }

    // MARK: - Init

    init(mode: ProfileMode) {
        self.mode = mode
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
    }

    override func didLoad() {
        super.didLoad()
        // avatarImageNode renders a pre-rounded image (corners baked
        // into the bitmap by CircularImageCache), so no cornerRadius
        // mask here — masks on overlapping circular nodes leak a 1-2px
        // antialiased ring of the underlying bg through the seam.
        avatarBackgroundNode.cornerRadius = 50
        avatarBackgroundNode.clipsToBounds = true
        editAvatarOverlayNode.cornerRadius = 50
        editAvatarOverlayNode.clipsToBounds = true
        messageButtonNode.cornerRadius = 12
        messageButtonNode.clipsToBounds = true
        settingsButtonNode.cornerRadius = 12
        settingsButtonNode.clipsToBounds = true
        logoutButtonNode.cornerRadius = 12
        logoutButtonNode.clipsToBounds = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(avatarTapped))
        editAvatarOverlayNode.view.addGestureRecognizer(tap)
        editAvatarOverlayNode.view.isUserInteractionEnabled = false // enabled only in edit mode

        let copyTap = UITapGestureRecognizer(target: self, action: #selector(copyUserId))
        userIdNode.view.addGestureRecognizer(copyTap)
        userIdNode.view.isUserInteractionEnabled = true
    }

    // MARK: - Public update

    func update(avatar: AvatarViewModel?, displayName: String?, userId: String) {
        avatarBackgroundNode.backgroundColor = avatar?.color ?? .systemGray4
        avatarInitialsNode.attributedText = NSAttributedString(
            string: avatar?.initials ?? "",
            attributes: [
                .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )

        if let mxc = avatar?.mxcAvatarURL {
            loadAvatarImage(mxcUrl: mxc)
        } else {
            avatarImageNode.image = nil
            setBackgroundVisible(true)
        }

        let name = displayName ?? userId
        displayNameNode.attributedText = NSAttributedString(
            string: name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.label
            ]
        )
        nameEditNode.attributedText = NSAttributedString(
            string: name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.label
            ]
        )

        userIdNode.attributedText = NSAttributedString(
            string: userId,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )

        setNeedsLayout()
    }

    func updateAvatarLocally(image: UIImage) {
        // One-shot local image (just-cropped, before SDK upload). No
        // stable cache key, so we use a UUID — adds one disposable
        // entry that LRU will rotate out.
        avatarImageNode.image = CircularImageCache.roundedImage(
            source: image, diameter: 100, cacheKey: UUID().uuidString
        )
        setBackgroundVisible(false)
    }

    private func loadAvatarImage(mxcUrl: String) {
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
            await MainActor.run {
                self?.avatarImageNode.image = rounded
                self?.setBackgroundVisible(false)
            }
        }
    }

    /// Bg + initials show only when there's no avatar image. Hiding
    /// (rather than alpha=0) skips the layer from compositing entirely.
    private func setBackgroundVisible(_ visible: Bool) {
        avatarBackgroundNode.isHidden = !visible
        avatarInitialsNode.isHidden = !visible
    }

    func updatePresence(_ presence: UserPresence?) {
        guard case .other = mode else { return }
        if let presence {
            let text: String
            let color: UIColor
            if presence.online {
                text = String(localized: "online")
                color = .systemGreen
            } else if let lastSeen = presence.lastSeen {
                text = lastSeen.presenceLastSeenString(style: .expanded)
                color = .secondaryLabel
            } else {
                presenceNode.attributedText = nil
                setNeedsLayout()
                return
            }
            presenceNode.attributedText = NSAttributedString(
                string: text,
                attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: color]
            )
        } else {
            presenceNode.attributedText = nil
        }
        setNeedsLayout()
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
        editAvatarOverlayNode.isHidden = !editing
        editAvatarOverlayNode.view.isUserInteractionEnabled = editing
        setNeedsLayout()
    }

    // MARK: - Setup

    private func setupNodes() {
        avatarBackgroundNode.backgroundColor = .systemGray4
        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        avatarImageNode.isOpaque = false

        // Edit overlay on avatar
        editAvatarOverlayNode.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        editAvatarOverlayNode.isHidden = true
        editAvatarIconNode.image = UIImage(systemName: "camera.fill")
        editAvatarIconNode.imageModificationBlock = ASImageNodeTintColorModificationBlock(.white)
        editAvatarIconNode.contentMode = .scaleAspectFit

        // Copy button
        let copyImage = UIImage(systemName: "doc.on.doc")
        copyButtonNode.setImage(copyImage, for: .normal)
        copyButtonNode.imageNode.tintColor = .secondaryLabel
        copyButtonNode.addTarget(self, action: #selector(copyUserId), forControlEvents: .touchUpInside)

        // Message button (visible only when onMessageTapped is set)
        messageButtonNode.setAttributedTitle(NSAttributedString(
            string: String(localized: "Message"),
            attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: UIColor.white]
        ), for: .normal)
        messageButtonNode.backgroundColor = .systemBlue
        messageButtonNode.contentEdgeInsets = UIEdgeInsets(top: 14, left: 32, bottom: 14, right: 32)
        messageButtonNode.addTarget(self, action: #selector(messageTapped), forControlEvents: .touchUpInside)

        // Search messages
        let searchIcon = UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        )
        searchButtonNode.setImage(searchIcon, for: .normal)
        searchButtonNode.setAttributedTitle(NSAttributedString(
            string: "  " + String(localized: "Search Messages"),
            attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]
        ), for: .normal)
        searchButtonNode.contentHorizontalAlignment = .middle
        searchButtonNode.addTarget(self, action: #selector(searchTapped), forControlEvents: .touchUpInside)

        // Settings (own only)
        let settingsIcon = AppIcon.settings.rendered(size: 17, weight: .medium, color: AppColor.accent)
        settingsButtonNode.setImage(settingsIcon, for: .normal)
        settingsButtonNode.setAttributedTitle(NSAttributedString(
            string: "  " + String(localized: "Settings"),
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: UIColor.label
            ]
        ), for: .normal)
        settingsButtonNode.backgroundColor = .secondarySystemBackground
        settingsButtonNode.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        settingsButtonNode.contentHorizontalAlignment = .left
        settingsButtonNode.addTarget(self, action: #selector(settingsTapped), forControlEvents: .touchUpInside)

        // Logout (own only)
        logoutButtonNode.setAttributedTitle(NSAttributedString(
            string: String(localized: "Sign Out"),
            attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: UIColor.white]
        ), for: .normal)
        logoutButtonNode.backgroundColor = .systemRed
        logoutButtonNode.contentEdgeInsets = UIEdgeInsets(top: 14, left: 32, bottom: 14, right: 32)
        logoutButtonNode.addTarget(self, action: #selector(logoutTapped), forControlEvents: .touchUpInside)
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Avatar
        let size = CGSize(width: 100, height: 100)
        avatarBackgroundNode.style.preferredSize = size
        avatarImageNode.style.preferredSize = size
        editAvatarOverlayNode.style.preferredSize = size
        editAvatarIconNode.style.preferredSize = CGSize(width: 28, height: 28)

        let initialsCenter = ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: .minimumXY, child: avatarInitialsNode)
        let withInitials = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: initialsCenter)
        var avatarSpec: ASLayoutSpec = ASOverlayLayoutSpec(child: withInitials, overlay: avatarImageNode)
        if isEditing {
            let iconCenter = ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: .minimumXY, child: editAvatarIconNode)
            let overlay = ASOverlayLayoutSpec(child: editAvatarOverlayNode, overlay: iconCenter)
            avatarSpec = ASOverlayLayoutSpec(child: avatarSpec, overlay: overlay)
        }

        // User ID row
        copyButtonNode.style.preferredSize = CGSize(width: 20, height: 20)
        let userIdRow = ASStackLayoutSpec(
            direction: .horizontal, spacing: 6,
            justifyContent: .center, alignItems: .center,
            children: [userIdNode, copyButtonNode]
        )

        // Name (editable or static)
        let nameSpec: ASLayoutSpec
        if isEditing {
            nameEditNode.style.minWidth = ASDimension(unit: .points, value: 150)
            nameSpec = ASWrapperLayoutSpec(layoutElement: nameEditNode)
        } else {
            nameSpec = ASWrapperLayoutSpec(layoutElement: displayNameNode)
        }

        // Profile info stack
        var infoChildren: [ASLayoutElement] = [avatarSpec, nameSpec, userIdRow]
        if case .other = mode, presenceNode.attributedText != nil {
            infoChildren.append(presenceNode)
        }

        let profileStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 8,
            justifyContent: .start, alignItems: .center,
            children: infoChildren
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        var bottomChildren: [ASLayoutElement] = []
        if case .other = mode {
            if onMessageTapped != nil {
                messageButtonNode.style.alignSelf = .stretch
                bottomChildren.append(messageButtonNode)
            }
            searchButtonNode.style.alignSelf = .stretch
            bottomChildren.append(searchButtonNode)
        }
        if case .own = mode {
            settingsButtonNode.style.alignSelf = .stretch
            logoutButtonNode.style.alignSelf = .stretch
            bottomChildren.append(contentsOf: [settingsButtonNode, logoutButtonNode])
        }

        let bottomStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 12,
            justifyContent: .end, alignItems: .stretch,
            children: bottomChildren
        )

        let mainStack = ASStackLayoutSpec(
            direction: .vertical, spacing: 0,
            justifyContent: .start, alignItems: .stretch,
            children: [profileStack, spacer, bottomStack]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 24, bottom: bottomInset, right: 24),
            child: mainStack
        )
    }

    // MARK: - Actions

    @objc private func avatarTapped() {
        onAvatarTapped?()
    }

    @objc private func copyUserId() {
        let text = userIdNode.attributedText?.string ?? ""
        UIPasteboard.general.string = text
    }

    @objc private func settingsTapped() {
        onSettingsTapped?()
    }

    @objc private func searchTapped() {
        onSearchTapped?()
    }

    @objc private func messageTapped() {
        onMessageTapped?()
    }

    @objc private func logoutTapped() {
        onLogoutTapped?()
    }

}
