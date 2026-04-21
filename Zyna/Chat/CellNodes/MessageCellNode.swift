//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Base class for all message cell nodes.
/// Handles context menu protocol, sender name, bubble styling, and the outer layout.
class MessageCellNode: ZynaCellNode, ContextMenuCellNode {

    /// Matches a single-line text bubble
    fileprivate static let avatarDiameter: CGFloat = 32
    fileprivate static let avatarThumbSize: Int = Int(avatarDiameter * ScreenConstants.scale)

    // MARK: - Context Menu

    var onContextMenuActivated: (() -> Void)?

    var onDragChanged: ((CGPoint) -> Void)? {
        get { contextSourceNode.onDragChanged }
        set { contextSourceNode.onDragChanged = newValue }
    }

    var onDragEnded: ((CGPoint) -> Void)? {
        get { contextSourceNode.onDragEnded }
        set { contextSourceNode.onDragEnded = newValue }
    }

    var onInteractionLockChanged: ((Bool) -> Void)? {
        get { contextSourceNode.onInteractionLockChanged }
        set { contextSourceNode.onInteractionLockChanged = newValue }
    }

    // MARK: - Reactions

    var onReactionTapped: ((String) -> Void)?

    // MARK: - Sender

    /// Fires with the sender's Matrix user ID on tap of the name or avatar.
    var onSenderTapped: ((String) -> Void)?

    // MARK: - Reply

    var onReplyHeaderTapped: ((String) -> Void)?
    private(set) var replyHeaderNode: ReplyHeaderNode?
    private(set) var forwardedHeaderNode: ASTextNode?


    // MARK: - Subnodes

    let bubbleNode = RoundedBackgroundNode()
    private let bubbleBackgroundNode = RoundedBackgroundNode()
    private let bubbleWrapperNode = ASDisplayNode()
    let contextSourceNode: ContextSourceNode
    let timeNode = ASTextNode()
    let statusIconNode: MessageStatusIconNode?
    let senderNameNode = ASTextNode()
    private(set) var reactionsNode: ReactionsNode?
    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()

    // MARK: - Gradient bubble

    /// Set by the cell factory: gradient view that message bubbles
    /// mirror via a portal with `matchesPosition=true`. Nil means the bubble
    /// falls back to its solid `fillColor`.
    weak var bubbleGradientSource: UIView? {
        didSet {
            applyBubbleChrome()
            updateBubblePortalSource()
        }
    }

    /// Holds the portal view alive. Built in `didLoad` when the cell
    /// has a shared gradient source; mask + frame
    /// updated in `layout()` so bubble-shape clipping tracks any
    /// post-layout changes (reactions added, cluster-flip, etc.).
    private var bubblePortal: PortalView?
    private var bubblePortalContainer: UIView?
    private var didReloadBubblePortalAfterReadyLayout = false
    private let bubbleBaseFillColor: UIColor

    // MARK: - State

    let isOutgoing: Bool
    let showSenderName: Bool
    /// Left-gutter slot is reserved (incoming + group); image
    /// visibility then depends on isLastInCluster.
    let reservesAvatarGutter: Bool
    private let senderId: String
    private let isFirstInCluster: Bool
    private var isLastInCluster: Bool
    let usesAccentBubbleStyle: Bool

    // MARK: - Init

    init(message: ChatMessage, isGroupChat: Bool = false) {
        self.isOutgoing = message.isOutgoing
        self.showSenderName = !message.isOutgoing && isGroupChat && message.isFirstInCluster
        self.reservesAvatarGutter = !message.isOutgoing && isGroupChat
        self.senderId = message.senderId
        self.isFirstInCluster = message.isFirstInCluster
        self.isLastInCluster = message.isLastInCluster
        let customColor = message.zynaAttributes.color
        let usesAccentBubbleStyle = message.isOutgoing || customColor != nil
        self.usesAccentBubbleStyle = usesAccentBubbleStyle
        let defaultFill = customColor
            ?? (message.isOutgoing ? AppColor.bubbleBackgroundOutgoing
                                   : AppColor.bubbleBackgroundIncoming)
        self.bubbleBaseFillColor = defaultFill
        self.contextSourceNode = ContextSourceNode(contentNode: bubbleWrapperNode)

        // Status icon only on the sender's own bubbles. For incoming
        // messages it carries no information and would just clutter.
        if message.isOutgoing,
           let iconState = MessageStatusIcon.from(sendStatus: message.sendStatus) {
            let node = MessageStatusIconNode()
            node.icon = iconState
            node.tintColour = usesAccentBubbleStyle
                ? AppColor.bubbleTimestampOutgoing
                : AppColor.bubbleTimestampIncoming
            self.statusIconNode = node
        } else {
            self.statusIconNode = nil
        }
        super.init()

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = Self.makeAccessibilityLabel(for: message)

        contextSourceNode.activated = { [weak self] _ in
            self?.onContextMenuActivated?()
        }

        automaticallyManagesSubnodes = true
        selectionStyle = .none
        // ASCellNode is wrapped in a UITableViewCell whose default
        // backgroundColor (.systemBackground) would otherwise occlude
        // the table's own background and break glass backdrop sampling.
        backgroundColor = .clear

        bubbleNode.radius = 14
        bubbleNode.fillColor = .clear
        bubbleNode.automaticallyManagesSubnodes = true
        bubbleBackgroundNode.radius = 14
        bubbleBackgroundNode.isUserInteractionEnabled = false
        bubbleWrapperNode.addSubnode(bubbleBackgroundNode)
        bubbleWrapperNode.addSubnode(bubbleNode)
        bubbleWrapperNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASBackgroundLayoutSpec(
                child: self.bubbleNode,
                background: self.bubbleBackgroundNode
            )
        }
        applyBubbleChrome()

        // Timestamp (default colors — override in subclass if needed)
        timeNode.attributedText = NSAttributedString(
                string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: bubbleTimestampColor
                ]
        )

        // Sender name
        if showSenderName, let name = message.senderDisplayName {
            let colorIndex = MessageCellHelpers.stableHash(message.senderId) % MessageCellHelpers.senderColors.count
            senderNameNode.attributedText = NSAttributedString(
                string: name,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: MessageCellHelpers.senderColors[colorIndex]
                ]
            )
            senderNameNode.onDidLoad { [weak self] node in
                node.view.isUserInteractionEnabled = true
                let tap = UITapGestureRecognizer(
                    target: self,
                    action: #selector(MessageCellNode.handleSenderTap)
                )
                node.view.addGestureRecognizer(tap)
            }
        }

        if reservesAvatarGutter {
            let avatarModel = AvatarViewModel(
                userId: message.senderId,
                displayName: message.senderDisplayName,
                mxcAvatarURL: message.senderAvatarUrl
            )
            avatarBackgroundNode.image = avatarModel.circleImage(
                diameter: Self.avatarDiameter, fontSize: 13
            )
            avatarBackgroundNode.isOpaque = false
            avatarBackgroundNode.backgroundColor = .clear
            // Image comes in already-rounded from CircularImageCache,
            // so the node does no corner work. Layer-only so taps fall
            // through to the background node which owns the gesture.
            avatarImageNode.isOpaque = false
            avatarImageNode.backgroundColor = .clear
            avatarImageNode.contentMode = .scaleAspectFill
            avatarImageNode.isLayerBacked = true

            let visible = isLastInCluster
            avatarBackgroundNode.alpha = visible ? 1 : 0
            avatarImageNode.alpha = visible ? 1 : 0

            if let mxc = message.senderAvatarUrl {
                let diameter = Self.avatarDiameter
                if let source = MediaCache.shared.cachedImage(forUrl: mxc, size: Self.avatarThumbSize) {
                    avatarImageNode.image = CircularImageCache.roundedImage(
                        source: source, diameter: diameter, cacheKey: mxc
                    )
                } else {
                    // Don't annotate this Task @MainActor. A single
                    // render is cheap but bursts of new avatars on
                    // scroll pile up and drop frames. Everything
                    // touched here is thread-safe:
                    // UIGraphicsImageRenderer, NSCache, ASImageNode.image.
                    Task { [weak self] in
                        guard let source = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: Self.avatarThumbSize) else { return }
                        let rounded = CircularImageCache.roundedImage(
                            source: source, diameter: diameter, cacheKey: mxc
                        )
                        self?.avatarImageNode.image = rounded
                    }
                }
            }

            avatarBackgroundNode.onDidLoad { [weak self] node in
                node.view.isUserInteractionEnabled = true
                let tap = UITapGestureRecognizer(
                    target: self,
                    action: #selector(MessageCellNode.handleSenderTap)
                )
                node.view.addGestureRecognizer(tap)
            }
        }

        // Forwarded header
        if let forwarderName = message.zynaAttributes.forwardedFrom {
            let node = ASTextNode()
            node.attributedText = NSAttributedString(
                string: "↗ " + String(localized: "Forwarded from \(forwarderName)"),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: bubbleTimestampColor
                ]
            )
            node.maximumNumberOfLines = 1
            self.forwardedHeaderNode = node
        }

        // Reply header
        if let replyInfo = message.replyInfo {
            let rh = ReplyHeaderNode(replyInfo: replyInfo, usesAccentStyle: usesAccentBubbleStyle)
            self.replyHeaderNode = rh

            // Handle quick taps on reply header via ContextSourceNode
            contextSourceNode.onQuickTap = { [weak self] point in
                guard let self, self.isNodeLoaded,
                      let replyView = self.replyHeaderNode?.view else { return }
                let replyPoint = self.contextSourceNode.view.convert(point, to: replyView)
                if replyView.bounds.contains(replyPoint) {
                    self.onReplyHeaderTapped?(replyInfo.eventId)
                }
            }
        }

        if !message.reactions.isEmpty {
            self.reactionsNode = makeReactionsNode(message.reactions)
        }
    }

    private static func makeAccessibilityLabel(for message: ChatMessage) -> String {
        var parts: [String] = []
        if let sender = message.senderDisplayName, !message.isOutgoing {
            parts.append(sender)
        }
        parts.append(message.content.textPreview)
        parts.append(MessageCellHelpers.timeFormatter.string(from: message.timestamp))
        if let reactionsText = reactionCountAccessibilityText(for: message.reactions) {
            parts.append(reactionsText)
        }
        return parts.joined(separator: ", ")
    }

    private static func reactionCountAccessibilityText(for reactions: [MessageReaction]) -> String? {
        let totalCount = reactions.reduce(0) { $0 + $1.count }
        guard totalCount > 0 else { return nil }
        return String(localized: "\(totalCount) reactions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleSenderTap() {
        onSenderTapped?(senderId)
    }

    private func makeReactionsNode(_ reactions: [MessageReaction]) -> ReactionsNode {
        let node = ReactionsNode(reactions: reactions)
        node.onReactionTapped = { [weak self] key in
            self?.onReactionTapped?(key)
        }
        node.style.maxWidth = ASDimension(
            unit: .points,
            value: ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        )
        return node
    }

    // MARK: - Gradient portal

    /// Main-thread hook: safe point to alloc the portal view (UIView
    /// subclass, alloc off-main is undefined behaviour).
    override func didLoad() {
        super.didLoad()
        installBubblePortalIfNeeded()
    }

    override func didEnterVisibleState() {
        super.didEnterVisibleState()
        guard usesBubblePortal else { return }
        reloadBubblePortal()
        // Visible-state callbacks can still race the final window/layout
        // settle on slower devices, so give the portal one more pass on
        // the next run loop.
        DispatchQueue.main.async { [weak self] in
            self?.reloadBubblePortal()
        }
    }

    private func installBubblePortalIfNeeded() {
        guard bubblePortal == nil else { return }
        guard let source = bubbleGradientSource else { return }
        guard let portal = PortalView(matchesPosition: true) else { return }
        let container = UIView()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        portal.sourceView = source
        bubbleWrapperNode.view.insertSubview(container, belowSubview: bubbleNode.view)
        container.addSubview(portal.view)
        // Re-trigger after the portal's view entered the hierarchy:
        // the setter above called `reload` while the view had no
        // superview, so the index-reinsert was a no-op and the
        // compositor may not have linked to the source.
        portal.reload()
        bubblePortal = portal
        bubblePortalContainer = container
        didReloadBubblePortalAfterReadyLayout = false
        if let source = source as? BubbleGradientSource {
            source.addPortal(portal)
        }
    }

    private func updateBubblePortalSource() {
        guard isNodeLoaded else { return }
        guard let portal = bubblePortal else {
            installBubblePortalIfNeeded()
            syncBubblePortalLayout(skipActivationReload: true)
            return
        }
        portal.sourceView = bubbleGradientSource
        bubblePortalContainer?.isHidden = bubbleGradientSource == nil
        didReloadBubblePortalAfterReadyLayout = false
        if let source = bubbleGradientSource as? BubbleGradientSource {
            source.addPortal(portal)
        }
        syncBubblePortalLayout(skipActivationReload: true)
    }

    /// Keep portal frame + bubble-shape mask in sync with the bubble's
    /// current bounds. Cell layout can re-run on in-place updates
    /// (status / cluster flip) and on width changes from reactions.
    private func syncBubblePortalLayout(skipActivationReload: Bool = false) {
        guard let portal = bubblePortal,
              let container = bubblePortalContainer else {
            return
        }
        container.frame = bubbleNode.frame
        portal.view.frame = container.bounds
        if portal.view.layer.mask != nil {
            portal.view.layer.mask = nil
        }
        let mask = (container.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = container.bounds
        mask.path = bubbleNode.currentPath().cgPath
        if container.layer.mask !== mask {
            container.layer.mask = mask
        }
        if !skipActivationReload,
           !didReloadBubblePortalAfterReadyLayout,
           reloadBubblePortalIfEligible() {
            didReloadBubblePortalAfterReadyLayout = true
        }
    }

    override func layout() {
        super.layout()
        syncBubblePortalLayout()
    }

    func reloadBubblePortal() {
        syncBubblePortalLayout(skipActivationReload: true)
        _ = reloadBubblePortalIfEligible()
    }

    @discardableResult
    private func reloadBubblePortalIfEligible() -> Bool {
        guard let portal = bubblePortal else {
            return false
        }
        guard portal.view.window != nil,
              bubbleGradientSource?.window != nil,
              !portal.view.bounds.isEmpty else {
            return false
        }
        portal.reload()
        return true
    }

    private var usesFallbackBubbleBackground: Bool {
        return usesBubblePortal
    }

    private func applyBubbleChrome() {
        bubbleNode.radius = 14
        bubbleBackgroundNode.radius = bubbleNode.radius
        bubbleNode.roundedCorners = .allCorners
        bubbleBackgroundNode.roundedCorners = bubbleNode.roundedCorners

        if usesFallbackBubbleBackground {
            bubbleBackgroundNode.fillColor = bubbleBaseFillColor
            bubbleNode.fillColor = .clear
        } else {
            bubbleBackgroundNode.fillColor = .clear
            bubbleNode.fillColor = bubbleBaseFillColor
        }
    }

    private var usesBubblePortal: Bool {
        bubbleGradientSource != nil
    }

    var bubbleForegroundColor: UIColor {
        usesAccentBubbleStyle ? AppColor.bubbleForegroundOutgoing : AppColor.bubbleForegroundIncoming
    }

    var bubbleTimestampColor: UIColor {
        usesAccentBubbleStyle ? AppColor.bubbleTimestampOutgoing : AppColor.bubbleTimestampIncoming
    }

    // MARK: - Layout

    /// Wraps the bubble in sender-name + spacer + alignment.
    /// Subclasses can override to customize pre-layout (e.g. set maxWidth),
    /// then call super.
    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        var columnChildren: [ASLayoutElement] = []

        if showSenderName {
            let nameInset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 0, left: 12, bottom: 2, right: 0),
                child: senderNameNode
            )
            columnChildren.append(nameInset)
        }

        columnChildren.append(contextSourceNode)

        if let reactionsNode {
            columnChildren.append(reactionsNode)
        }

        let column = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 4,
            justifyContent: .start,
            alignItems: isOutgoing ? .end : .start,
            children: columnChildren
        )

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let hStack = ASStackLayoutSpec.horizontal()
        hStack.spacing = 4
        hStack.alignItems = .start

        if isOutgoing {
            hStack.children = [spacer, column]
        } else if reservesAvatarGutter {
            hStack.children = [buildAvatarSlot(), column, spacer]
        } else {
            hStack.children = [column, spacer]
        }

        // Only top is cluster-aware; bottom stays fixed so cell
        // height doesn't jump when isLastInCluster flips in place.
        var insets = MessageCellHelpers.cellInsets
        if isFirstInCluster {
            insets.top = MessageCellHelpers.clusterBreakTopInset
        }
        return ASInsetLayoutSpec(insets: insets, child: hStack)
    }

    /// Fixed-width slot; the avatar image is hidden via alpha on
    /// non-last bubbles so the whole cluster stays horizontally aligned.
    private func buildAvatarSlot() -> ASLayoutElement {
        let overlay = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)
        overlay.style.preferredSize = CGSize(width: Self.avatarDiameter, height: Self.avatarDiameter)
        // Anchored to the bottom so the avatar sits by the last bubble
        // of the cluster, not the first.
        overlay.style.alignSelf = .end
        return overlay
    }

    // MARK: - In-Place Update

    /// Returns true if the change between old and new can be applied
    /// without recreating the cell (send-status, cluster-membership,
    /// or reactions change — all are lightweight).
    static func canUpdateInPlace(old: ChatMessage, new: ChatMessage) -> Bool {
        old.id == new.id
            && old.content == new.content
            && old.zynaAttributes == new.zynaAttributes
            && old.replyInfo == new.replyInfo
            && old.senderDisplayName == new.senderDisplayName
            && old.senderAvatarUrl == new.senderAvatarUrl
    }

    /// Update send-status icon without recreating the cell.
    func updateSendStatus(_ status: String) {
        guard let iconNode = statusIconNode,
              let newIcon = MessageStatusIcon.from(sendStatus: status)
        else { return }
        iconNode.icon = newIcon
    }

    /// Alpha-toggles the avatar when a new same-sender message pushes
    /// this cell out of the "last in cluster" slot. Layout is stable,
    /// and alpha=0 layers are compositor-skipped — hiding is free.
    func updateClusterMembership(isLastInCluster: Bool) {
        guard reservesAvatarGutter, self.isLastInCluster != isLastInCluster else { return }
        self.isLastInCluster = isLastInCluster
        let alpha: CGFloat = isLastInCluster ? 1 : 0
        avatarBackgroundNode.alpha = alpha
        avatarImageNode.alpha = alpha
    }

    func updateReactions(_ reactions: [MessageReaction]) {
        switch (reactionsNode, reactions.isEmpty) {
        case let (node?, false):
            node.update(reactions: reactions)
        case (.none, false):
            reactionsNode = makeReactionsNode(reactions)
        case (.some, true):
            reactionsNode = nil
        case (.none, true):
            return
        }
        setNeedsLayout()
    }

    func updateAccessibilityMessage(_ message: ChatMessage) {
        accessibilityLabel = Self.makeAccessibilityLabel(for: message)
    }

    // MARK: - Highlight

    func highlightBubble() {
        guard isNodeLoaded else { return }
        let highlight = CAShapeLayer()
        highlight.frame = bubbleNode.bounds
        highlight.path = bubbleNode.currentPath().cgPath
        highlight.fillColor = bubbleForegroundColor
            .withAlphaComponent(0.3).cgColor
        highlight.opacity = 0
        bubbleNode.layer.addSublayer(highlight)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak highlight] in
            highlight?.removeFromSuperlayer()
        }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 1, 1, 0]
        anim.keyTimes = [0, 0.2, 0.6, 1.0]
        anim.duration = 0.8
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        highlight.add(anim, forKey: "highlight")

        CATransaction.commit()
    }

    // MARK: - Context Menu Reparenting

    func extractBubbleForMenu(in coordinateSpace: UICoordinateSpace) -> (node: ASDisplayNode, frame: CGRect)? {
        guard isNodeLoaded else { return nil }
        return contextSourceNode.extractContentForMenu(in: coordinateSpace)
    }

    func restoreBubbleFromMenu() {
        contextSourceNode.restoreContentFromMenu()
    }
}
