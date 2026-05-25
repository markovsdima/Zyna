//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class PublicRoomPreviewViewController: ASDKViewController<PublicRoomPreviewNode> {

    var onBack: (() -> Void)?
    var onJoinTapped: (() -> Void)?

    private let publicRoom: PublicRoomSearchResult
    private let glassTopBar = GlassTopBar()
    private var isJoined: Bool

    init(publicRoom: PublicRoomSearchResult, isJoined: Bool) {
        self.publicRoom = publicRoom
        self.isJoined = isJoined
        super.init(node: PublicRoomPreviewNode())
        hidesBottomBarWhenPushed = true
        node.update(publicRoom: publicRoom, isJoined: isJoined)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupGlassTopBar()
        node.joinButtonNode.addTarget(self, action: #selector(joinTapped), forControlEvents: .touchUpInside)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
        let targetTopInset = glassTopBar.coveredHeight + 24
        if abs(node.topInset - targetTopInset) > 0.5 {
            node.topInset = targetTopInset
            node.setNeedsLayout()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        node.bottomInset = max(view.safeAreaInsets.bottom + 24, 24)
        node.setNeedsLayout()
    }

    func setJoining(_ isJoining: Bool) {
        node.setJoining(isJoining, isJoined: isJoined)
    }

    func setJoined(_ isJoined: Bool) {
        self.isJoined = isJoined
        node.setJoining(false, isJoined: isJoined)
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = node.contentNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        let backIcon = AppIcon.chevronBackward.template(size: 17, weight: .semibold)
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .flexibleSpace
        ]
    }

    @objc private func joinTapped() {
        onJoinTapped?()
    }
}

final class PublicRoomPreviewNode: ScreenNode {

    let contentNode = ASDisplayNode()
    let joinButtonNode = AccessibleButtonNode()

    weak var glassTopBar: GlassTopBar?

    var topInset: CGFloat = 88
    var bottomInset: CGFloat = 24

    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let nameNode = ASTextNode()
    private let addressNode = ASTextNode()
    private let memberCountNode = ASTextNode()
    private let topicNode = ASTextNode()

    private var showsTopic = false
    private var avatarLoadRevision: UInt64 = 0

    override init() {
        super.init()
        setupNodes()
    }

    func update(publicRoom: PublicRoomSearchResult, isJoined: Bool) {
        avatarLoadRevision &+= 1
        let revision = avatarLoadRevision
        let avatar = AvatarViewModel(
            userId: publicRoom.alias ?? publicRoom.roomId,
            displayName: publicRoom.name,
            mxcAvatarURL: publicRoom.avatarURL
        )

        avatarBackgroundNode.image = avatar.circleImage(diameter: 112, fontSize: 38)
        avatarImageNode.image = nil

        if let mxc = publicRoom.avatarURL {
            let diameter: CGFloat = 112
            let size = Int(diameter * ScreenConstants.scale)
            if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: size) {
                avatarImageNode.image = CircularImageCache.roundedImage(
                    source: cached,
                    diameter: diameter,
                    cacheKey: mxc
                )
            } else {
                Task { [weak self] in
                    guard let source = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) else {
                        return
                    }
                    let rounded = CircularImageCache.roundedImage(
                        source: source,
                        diameter: diameter,
                        cacheKey: mxc
                    )
                    await MainActor.run { [weak self] in
                        guard let self, self.avatarLoadRevision == revision else { return }
                        self.avatarImageNode.image = rounded
                    }
                }
            }
        }

        nameNode.attributedText = NSAttributedString(
            string: publicRoom.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: UIColor.label
            ]
        )

        addressNode.attributedText = NSAttributedString(
            string: publicRoom.matrixAddress,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )

        memberCountNode.attributedText = NSAttributedString(
            string: publicRoom.memberCountText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )

        let topic = publicRoom.topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showsTopic = !topic.isEmpty
        topicNode.attributedText = NSAttributedString(
            string: topic,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.label
            ]
        )

        setJoining(false, isJoined: isJoined)
        setNeedsLayout()
    }

    func setJoining(_ isJoining: Bool, isJoined: Bool) {
        joinButtonNode.isEnabled = !isJoining
        joinButtonNode.alpha = isJoining ? 0.6 : 1

        let title: String
        let icon: UIImage
        if isJoining {
            title = String(localized: "Joining...")
            icon = AppIcon.personBadgePlus.rendered(size: 18, weight: .semibold, color: .white)
        } else if isJoined {
            title = String(localized: "Open Room")
            icon = AppIcon.bubbleLeft.rendered(size: 18, weight: .semibold, color: .white)
        } else {
            title = String(localized: "Join Room")
            icon = AppIcon.personBadgePlus.rendered(size: 18, weight: .semibold, color: .white)
        }

        joinButtonNode.setImage(icon, for: .normal)
        joinButtonNode.setAttributedTitle(
            NSAttributedString(
                string: title,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                    .foregroundColor: UIColor.white
                ]
            ),
            for: .normal
        )
        joinButtonNode.accessibilityLabel = title
    }

    private func setupNodes() {
        contentNode.backgroundColor = .appBG

        avatarBackgroundNode.isLayerBacked = true
        avatarImageNode.isLayerBacked = true
        avatarImageNode.isOpaque = false
        avatarImageNode.contentMode = .scaleAspectFill

        nameNode.maximumNumberOfLines = 2
        nameNode.truncationMode = .byTruncatingTail
        addressNode.maximumNumberOfLines = 2
        addressNode.truncationMode = .byTruncatingMiddle
        memberCountNode.maximumNumberOfLines = 1
        topicNode.maximumNumberOfLines = 4
        topicNode.truncationMode = .byTruncatingTail

        joinButtonNode.backgroundColor = AppColor.accent
        joinButtonNode.cornerRadius = 12
        joinButtonNode.clipsToBounds = true
        joinButtonNode.contentSpacing = 10
        joinButtonNode.contentEdgeInsets = UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        joinButtonNode.style.height = ASDimension(unit: .points, value: 52)
        joinButtonNode.accessibilityTraits = .button
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let avatarSize = CGSize(width: 112, height: 112)
        avatarBackgroundNode.style.preferredSize = avatarSize
        avatarImageNode.style.preferredSize = avatarSize
        let avatarSpec = ASOverlayLayoutSpec(
            child: avatarBackgroundNode,
            overlay: avatarImageNode
        )

        let titleStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 8,
            justifyContent: .start,
            alignItems: .center,
            children: [nameNode, addressNode, memberCountNode]
        )
        titleStack.style.alignSelf = .stretch

        var headerChildren: [ASLayoutElement] = [avatarSpec, titleStack]
        if showsTopic {
            let topicInset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 8, left: 0, bottom: 0, right: 0),
                child: topicNode
            )
            topicInset.style.alignSelf = .stretch
            headerChildren.append(topicInset)
        }

        let headerStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 18,
            justifyContent: .start,
            alignItems: .center,
            children: headerChildren
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1
        joinButtonNode.style.alignSelf = .stretch

        let mainStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 24,
            justifyContent: .start,
            alignItems: .stretch,
            children: [headerStack, spacer, joinButtonNode]
        )

        let inset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 24, bottom: bottomInset, right: 24),
            child: mainStack
        )
        return ASBackgroundLayoutSpec(child: inset, background: contentNode)
    }
}

private extension PublicRoomSearchResult {
    var matrixAddress: String {
        alias ?? roomId
    }

    var memberCountText: String {
        joinedMembers == 1
            ? String(localized: "1 member")
            : String(localized: "\(joinedMembers) members")
    }
}
