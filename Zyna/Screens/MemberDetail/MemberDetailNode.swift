//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class MemberDetailNode: ScreenNode {

    var onRoleTapped: (() -> Void)?
    var onSendMessageTapped: (() -> Void)?
    var onKickTapped: (() -> Void)?
    var onBanTapped: (() -> Void)?

    /// Set by the VC after the bar is configured. Lets us put the bar
    /// first in the a11y tree — otherwise VO walks subview order and
    /// reaches the bar last (it's added on top, so it's last subview).
    weak var glassTopBar: GlassTopBar?

    // MARK: - Subnodes

    /// Sampling target for the glass top bar. Without it, glass falls
    /// back to the window — which includes the glass renderer itself.
    let contentNode = ASDisplayNode()

    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let nameNode = ASTextNode()
    private let userIdNode = ASTextNode()

    private let roleLabel = ASTextNode()
    private let rolePillBackground = RoundedBackgroundNode()
    private let roleText = ASTextNode()
    private let roleChevron = ASImageNode()
    /// Background fill for the row. Sibling of `roleRow` so the latter
    /// stays a transparent tap/a11y target on top.
    private let roleRowBackground = RoundedBackgroundNode()
    private let roleRow = TappableNode()

    private var sendMessageButton: ColoredActionButtonNode?
    private var kickButton: ColoredActionButtonNode?
    private var banButton: ColoredActionButtonNode?
    /// Key of inputs that drive button identity. Stable across presence
    /// or role updates, so buttons don't get rebuilt and flash.
    private var lastButtonsKey: String?

    private var topInset: CGFloat = 40
    private var state: MemberDetailViewModel.State = .init()

    // MARK: - Init

    override init() {
        super.init()
        setupStaticNodes()
        roleRow.onTap = { [weak self] in self?.roleRowTapped() }
    }

    private func setupStaticNodes() {
        avatarBackgroundNode.isLayerBacked = true
        avatarBackgroundNode.isOpaque = false
        avatarImageNode.isLayerBacked = true
        avatarImageNode.isOpaque = false
        avatarImageNode.contentMode = .scaleAspectFill

        nameNode.maximumNumberOfLines = 1
        userIdNode.maximumNumberOfLines = 1

        roleLabel.attributedText = NSAttributedString(
            string: String(localized: "Role"),
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.label
            ]
        )

        rolePillBackground.radius = 9
        roleChevron.style.preferredSize = CGSize(width: 12, height: 12)
        roleRowBackground.fillColor = .secondarySystemBackground
        roleRowBackground.radius = 12
        roleRow.backgroundColor = .clear
    }

    override func didLoad() {
        super.didLoad()
        avatarBackgroundNode.cornerRadius = 50
        avatarBackgroundNode.clipsToBounds = true
        avatarImageNode.cornerRadius = 50
        avatarImageNode.clipsToBounds = true

        roleChevron.image = AppIcon.chevronDown.rendered(
            size: 12, weight: .semibold, color: .secondaryLabel
        )
    }

    private func roleRowTapped() {
        guard state.canChangeRole else { return }
        onRoleTapped?()
    }

    /// Frame of the role row in this node's coord space; popup anchor.
    var roleRowFrame: CGRect {
        guard isNodeLoaded else { return .zero }
        return roleRow.frame
    }

    /// VO target for restoring focus after the role picker dismisses.
    var roleRowAccessibilityView: UIView? {
        roleRow.isNodeLoaded ? roleRow.view : nil
    }

    // MARK: - State update

    func setTopInset(_ inset: CGFloat) {
        topInset = inset
        setNeedsLayout()
    }

    func apply(state: MemberDetailViewModel.State) {
        self.state = state
        guard let member = state.member else { return }
        applyHeader(member: member)
        applyRole(member: member, canChange: state.canChangeRole)
        applyButtons()
        setNeedsLayout()
    }

    private func applyHeader(member: MemberCellNode.Model) {
        let avatar = AvatarViewModel(
            userId: member.userId,
            displayName: member.displayName,
            mxcAvatarURL: member.avatarUrl
        )
        avatarBackgroundNode.image = avatar.circleImage(diameter: 100, fontSize: 36)

        if let mxc = member.avatarUrl {
            let diameter: CGFloat = 100
            let thumb = Int(diameter * ScreenConstants.scale)
            if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: thumb) {
                avatarImageNode.image = CircularImageCache.roundedImage(
                    source: cached, diameter: diameter, cacheKey: mxc
                )
            } else {
                Task { [weak self] in
                    guard let source = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: thumb) else { return }
                    let rounded = CircularImageCache.roundedImage(
                        source: source, diameter: diameter, cacheKey: mxc
                    )
                    self?.avatarImageNode.image = rounded
                }
            }
        }

        nameNode.attributedText = NSAttributedString(
            string: member.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.label
            ]
        )
        userIdNode.attributedText = NSAttributedString(
            string: member.userId,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    private func applyRole(member: MemberCellNode.Model, canChange: Bool) {
        rolePillBackground.fillColor = member.role.pillColor == .clear
            ? .systemGray3
            : member.role.pillColor
        roleText.attributedText = NSAttributedString(
            string: member.role.localizedLabel,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )
        roleChevron.alpha = canChange ? 1 : 0

        // Collapse roleLabel + pill + chevron into one VO element so
        // VO reads the row as a whole, not as three separate fragments.
        roleRow.isAccessibilityElement = true
        roleRow.accessibilityLabel = "\(String(localized: "Role")), \(member.role.localizedLabel)"
        roleRow.accessibilityTraits = canChange ? .button : []
        // VO already announces the activation gesture; the hint should
        // describe the outcome, not how to perform it.
        roleRow.accessibilityHint = canChange ? String(localized: "Changes member role") : nil
    }

    private func applyButtons() {
        // Key intentionally omits role: button identity (presence,
        // labels, actions) doesn't depend on the role enum — it's
        // gated only by capability flags + membership state. Add role
        // here if a future button gains role-specific text/icon.
        let key = "\(state.canSendMessage)|\(state.canKick)|\(state.canBan)|\(state.membership)"
        guard key != lastButtonsKey else { return }
        lastButtonsKey = key

        sendMessageButton = nil
        kickButton = nil
        banButton = nil

        if state.canSendMessage {
            let btn = ColoredActionButtonNode(
                title: String(localized: "Send Message"),
                icon: AppIcon.bubbleLeft.rendered(size: 16, weight: .semibold, color: .white),
                style: .primary
            )
            btn.onTap = { [weak self] in self?.onSendMessageTapped?() }
            sendMessageButton = btn
        }

        if state.canKick {
            let isInvite = state.membership == .invite
            let title = isInvite ? String(localized: "Cancel Invite") : String(localized: "Kick from Group")
            let icon: AppIcon = isInvite ? .personBadgeMinus : .personSlash
            let btn = ColoredActionButtonNode(
                title: title,
                icon: icon.rendered(size: 16, weight: .semibold, color: .white),
                style: .warning
            )
            btn.onTap = { [weak self] in self?.onKickTapped?() }
            kickButton = btn
        }

        // Ban only makes sense for joined users — invites can be revoked.
        if state.canBan, state.membership == .join {
            let btn = ColoredActionButtonNode(
                title: String(localized: "Ban from Group"),
                icon: AppIcon.noSign.rendered(size: 16, weight: .semibold, color: .white),
                style: .destructive
            )
            btn.onTap = { [weak self] in self?.onBanTapped?() }
            banButton = btn
        }
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        avatarBackgroundNode.style.preferredSize = CGSize(width: 100, height: 100)
        avatarImageNode.style.preferredSize = CGSize(width: 100, height: 100)
        let avatar = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)

        let header = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 10,
            justifyContent: .start,
            alignItems: .center,
            children: [avatar, nameNode, userIdNode]
        )

        let pillInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8),
            child: roleText
        )
        let pillWithBg = ASBackgroundLayoutSpec(child: pillInset, background: rolePillBackground)
        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        var rightChildren: [ASLayoutElement] = [pillWithBg]
        if state.canChangeRole {
            rightChildren.append(roleChevron)
        }
        let right = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .end,
            alignItems: .center,
            children: rightChildren
        )
        let rowContent = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: [roleLabel, spacer, right]
        )
        let rowPadded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16),
            child: rowContent
        )
        // Order: bg fill → padded content → transparent tap/a11y layer.
        let withBg = ASBackgroundLayoutSpec(child: rowPadded, background: roleRowBackground)
        let roleRowSpec = ASOverlayLayoutSpec(child: withBg, overlay: roleRow)

        var buttons: [ASLayoutElement] = []
        if let sendMessageButton { buttons.append(sendMessageButton) }
        if let kickButton { buttons.append(kickButton) }
        if let banButton { buttons.append(banButton) }

        var sections: [ASLayoutElement] = [header, roleRowSpec]
        if !buttons.isEmpty {
            let buttonsStack = ASStackLayoutSpec(
                direction: .vertical,
                spacing: 12,
                justifyContent: .start,
                alignItems: .stretch,
                children: buttons
            )
            sections.append(buttonsStack)
        }

        let main = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 28,
            justifyContent: .start,
            alignItems: .stretch,
            children: sections
        )
        let inset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: topInset, left: 20, bottom: 16, right: 20),
            child: main
        )
        return ASBackgroundLayoutSpec(child: inset, background: contentNode)
    }

    // MARK: - Accessibility

    /// Bar before content. Default subview-walk would put the bar last
    /// (it's the topmost subview), so VO swipe order would reach it
    /// only after stepping through avatar/role/buttons.
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
