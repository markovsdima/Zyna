//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Base class for all message cell nodes.
/// Handles context menu protocol, sender name, bubble styling, and the outer layout.
class MessageCellNode: ZynaCellNode, ContextMenuCellNode {

    private static let portalFallbackBackgroundEnabled = false

    /// Matches a single-line text bubble
    fileprivate static let avatarDiameter: CGFloat = 32
    fileprivate static let avatarThumbSize: Int = Int(avatarDiameter * ScreenConstants.scale)

    // MARK: - Context Menu

    var onContextMenuActivated: ((CGPoint) -> Void)?

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
    private let bubblePortalBackgroundNode = BubblePortalBackgroundNode()
    let directBubbleContentNode = ASDisplayNode()
    private let bubbleWrapperNode = ASDisplayNode()
    let contextSourceNode: ContextSourceNode
    let timeNode = ASTextNode()
    let statusIconNode: MessageStatusIconNode?
    let senderNameNode = ASTextNode()
    private(set) var reactionsNode: ReactionsNode?
    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()

    // MARK: - Gradient bubble

    /// Shared source host resolved by `ChatNode` on the main thread.
    /// The bubble background mirrors this source through a thin portal
    /// node; nil means the bubble falls back to its solid fill color.
    weak var bubbleGradientSource: PortalSourceView? {
        didSet {
            applyBubbleChrome()
            bubblePortalBackgroundNode.sourceView = usesBubblePortal ? bubbleGradientSource : nil
        }
    }
    private let bubbleBaseFillColor: UIColor

    // MARK: - State

    let isOutgoing: Bool
    let messageId: String
    let showSenderName: Bool
    /// Left-gutter slot is reserved (incoming + group); image
    /// visibility then depends on isLastInCluster.
    let reservesAvatarGutter: Bool
    private let senderId: String
    private let isFirstInCluster: Bool
    private var isLastInCluster: Bool
    let mediaGroupPosition: MediaGroupPosition?
    private let rendersCompositeMediaBubble: Bool
    let usesAccentBubbleStyle: Bool
    var allowsInteractiveActions = true {
        didSet {
            applyInteractiveActionsState()
        }
    }
    private var showsBubbleChrome = true
    private var usesBareBubbleContent = false

    // MARK: - Init

    init(message: ChatMessage, isGroupChat: Bool = false) {
        self.isOutgoing = message.isOutgoing
        self.messageId = message.id
        self.showSenderName = !message.isOutgoing && isGroupChat && message.isFirstInCluster
        self.reservesAvatarGutter = !message.isOutgoing && isGroupChat
        self.senderId = message.senderId
        self.isFirstInCluster = message.isFirstInCluster
        self.isLastInCluster = message.isLastInCluster
        self.mediaGroupPosition = message.mediaGroupPresentation?.position
        self.rendersCompositeMediaBubble = message.mediaGroupPresentation?.rendersCompositeBubble == true
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
           let iconState = MessageStatusIcon.from(sendStatus: message.effectiveSendStatus) {
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

        contextSourceNode.activated = { [weak self] point in
            self?.onContextMenuActivated?(point)
        }

        automaticallyManagesSubnodes = true
        selectionStyle = .none
        // ASCellNode is wrapped in a UITableViewCell whose default
        // backgroundColor (.systemBackground) would otherwise occlude
        // the table's own background and break glass backdrop sampling.
        backgroundColor = .clear

        bubbleNode.radius = MessageCellHelpers.bubbleCornerRadius
        bubbleNode.fillColor = .clear
        bubbleNode.automaticallyManagesSubnodes = true
        directBubbleContentNode.automaticallyManagesSubnodes = true
        directBubbleContentNode.isHidden = true
        bubbleBackgroundNode.radius = MessageCellHelpers.bubbleCornerRadius
        bubbleBackgroundNode.isUserInteractionEnabled = false
        bubblePortalBackgroundNode.isUserInteractionEnabled = false
        bubbleWrapperNode.addSubnode(bubbleBackgroundNode)
        bubbleWrapperNode.addSubnode(bubblePortalBackgroundNode)
        bubbleWrapperNode.addSubnode(bubbleNode)
        bubbleWrapperNode.addSubnode(directBubbleContentNode)
        bubbleWrapperNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            if self.usesBareBubbleContent {
                return ASWrapperLayoutSpec(layoutElement: self.directBubbleContentNode)
            }
            guard self.showsBubbleChrome else {
                return ASWrapperLayoutSpec(layoutElement: self.bubbleNode)
            }
            let layeredBackground = ASOverlayLayoutSpec(
                child: self.bubbleBackgroundNode,
                overlay: self.bubblePortalBackgroundNode
            )
            return ASBackgroundLayoutSpec(
                child: self.bubbleNode,
                background: layeredBackground
            )
        }
        applyBubbleChrome()

        // Timestamp (default colors — override in subclass if needed)
        timeNode.attributedText = NSAttributedString(
                string: MessageCellHelpers.timelineTimestampText(for: message),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: bubbleTimestampColor
                ]
        )

        // Sender name
        if showSenderName, let name = message.senderDisplayName {
            let fallbackColorIndex = MessageCellHelpers.stableHash(message.senderId) % MessageCellHelpers.senderColors.count
            let senderColor = message.senderNameColorHex
                .flatMap(UIColor.fromHexString)
                ?? MessageCellHelpers.senderColors[fallbackColorIndex]
            senderNameNode.attributedText = NSAttributedString(
                string: name,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: senderColor
                ]
            )
            senderNameNode.onDidLoad { [weak self] node in
                guard let self, self.allowsInteractiveActions else {
                    node.view.isUserInteractionEnabled = false
                    return
                }
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
                mxcAvatarURL: message.senderAvatarUrl,
                colorOverrideHex: message.senderNameColorHex
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
                guard let self, self.allowsInteractiveActions else {
                    node.view.isUserInteractionEnabled = false
                    return
                }
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
        parts.append(MessageCellHelpers.timelineTimestampText(for: message))
        if message.isEditPending {
            parts.append(String(localized: "edit pending"))
        }
        if message.isEditFailed {
            parts.append(String(localized: "edit failed"))
        }
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

    override func didLoad() {
        super.didLoad()
        assignProbeLayerNames()
    }

    @objc private func handleSenderTap() {
        guard allowsInteractiveActions else { return }
        onSenderTapped?(senderId)
    }

    private func makeReactionsNode(_ reactions: [MessageReaction]) -> ReactionsNode {
        let node = ReactionsNode(reactions: reactions)
        node.onReactionTapped = { [weak self] key in
            self?.onReactionTapped?(key)
        }
        node.isUserInteractionEnabled = allowsInteractiveActions
        node.style.maxWidth = ASDimension(
            unit: .points,
            value: ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        )
        return node
    }

    private func applyInteractiveActionsState() {
        contextSourceNode.isGestureEnabled = allowsInteractiveActions
        senderNameNode.isUserInteractionEnabled = allowsInteractiveActions
        avatarBackgroundNode.isUserInteractionEnabled = allowsInteractiveActions
        reactionsNode?.isUserInteractionEnabled = allowsInteractiveActions
    }

    private var usesFallbackBubbleBackground: Bool {
        return usesBubblePortal && Self.portalFallbackBackgroundEnabled
    }

    private func applyBubbleChrome() {
        directBubbleContentNode.isHidden = !usesBareBubbleContent
        bubbleNode.isHidden = usesBareBubbleContent

        guard !usesBareBubbleContent else {
            bubbleBackgroundNode.fillColor = .clear
            bubbleBackgroundNode.isHidden = true
            bubblePortalBackgroundNode.isHidden = true
            bubblePortalBackgroundNode.sourceView = nil
            bubbleNode.fillColor = .clear
            return
        }

        bubbleNode.radius = MessageCellHelpers.bubbleCornerRadius
        bubbleBackgroundNode.radius = bubbleNode.radius
        bubblePortalBackgroundNode.radius = bubbleNode.radius
        bubbleNode.roundedCorners = .allCorners
        bubbleBackgroundNode.roundedCorners = bubbleNode.roundedCorners
        bubblePortalBackgroundNode.roundedCorners = bubbleNode.roundedCorners

        guard showsBubbleChrome else {
            bubbleBackgroundNode.fillColor = .clear
            bubbleBackgroundNode.isHidden = true
            bubblePortalBackgroundNode.isHidden = true
            bubblePortalBackgroundNode.sourceView = nil
            bubbleNode.fillColor = .clear
            return
        }

        bubbleBackgroundNode.isHidden = usesBubblePortal && !usesFallbackBubbleBackground
        bubblePortalBackgroundNode.isHidden = !usesBubblePortal

        if usesBubblePortal {
            bubbleBackgroundNode.fillColor = usesFallbackBubbleBackground ? bubbleBaseFillColor : .clear
            bubbleNode.fillColor = .clear
        } else {
            bubbleBackgroundNode.fillColor = .clear
            bubbleNode.fillColor = bubbleBaseFillColor
        }
    }

    private var usesBubblePortal: Bool {
        showsBubbleChrome && bubbleGradientSource != nil
    }

    func setShowsBubbleChrome(_ enabled: Bool) {
        guard showsBubbleChrome != enabled else { return }
        showsBubbleChrome = enabled
        applyBubbleChrome()
        bubbleWrapperNode.setNeedsLayout()
        contextSourceNode.setNeedsLayout()
        setNeedsLayout()
    }

    func setUsesBareBubbleContent(_ enabled: Bool) {
        guard usesBareBubbleContent != enabled else { return }
        usesBareBubbleContent = enabled
        applyBubbleChrome()
        bubbleWrapperNode.setNeedsLayout()
        contextSourceNode.setNeedsLayout()
        setNeedsLayout()
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

        var insets = MessageCellHelpers.cellInsets
        if rendersCompositeMediaBubble {
            if isFirstInCluster {
                insets.top = MessageCellHelpers.clusterBreakTopInset
            }
        } else if let mediaGroupPosition {
            insets.top = mediaGroupPosition == .top
                ? MessageCellHelpers.clusterBreakTopInset
                : 0
            insets.bottom = mediaGroupPosition == .bottom
                ? MessageCellHelpers.cellInsets.bottom
                : 0
        } else if isFirstInCluster {
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
        guard stableDisplayIdentity(for: old) == stableDisplayIdentity(for: new),
              old.replyInfo == new.replyInfo,
              old.senderDisplayName == new.senderDisplayName,
              old.senderAvatarUrl == new.senderAvatarUrl,
              old.isFirstInCluster == new.isFirstInCluster,
              old.isEdited == new.isEdited,
              mediaGroupPresentationIsVisuallyEquivalent(old: old.mediaGroupPresentation, new: new.mediaGroupPresentation)
        else {
            return false
        }

        if isVisuallyEquivalentCompositeMediaGroupRow(old: old, new: new) {
            return true
        }

        if isVisuallyEquivalentPendingOutgoingEnvelope(old: old, new: new) {
            return true
        }

        return old.content == new.content
            && old.zynaAttributes == new.zynaAttributes
    }

    private static func stableDisplayIdentity(for message: ChatMessage) -> String {
        if let presentation = message.mediaGroupPresentation {
            if presentation.rendersCompositeBubble {
                return "media-group:\(presentation.id):composite"
            }
            if presentation.hidesStandaloneBubble,
               let mediaGroup = message.zynaAttributes.mediaGroup {
                return "media-group:\(presentation.id):hidden:\(mediaGroup.index)"
            }
        }
        return message.transactionId ?? message.eventId ?? message.id
    }

    private static func isVisuallyEquivalentPendingOutgoingEnvelope(
        old: ChatMessage,
        new: ChatMessage
    ) -> Bool {
        guard old.outgoingEnvelopeId != nil,
              old.outgoingEnvelopeId == new.outgoingEnvelopeId,
              old.zynaAttributes == new.zynaAttributes
        else {
            return false
        }

        switch (old.content, new.content) {
        case (.image(_, let oldWidth, let oldHeight, let oldCaption, let oldPreview),
              .image(_, let newWidth, let newHeight, let newCaption, let newPreview)):
            return oldWidth == newWidth
                && oldHeight == newHeight
                && oldCaption == newCaption
                && oldPreview == newPreview
        case (.video(_, _, let oldWidth, let oldHeight, let oldDuration, let oldFilename, let oldMime, let oldSize, let oldCaption, let oldPreview),
              .video(_, _, let newWidth, let newHeight, let newDuration, let newFilename, let newMime, let newSize, let newCaption, let newPreview)):
            return oldWidth == newWidth
                && oldHeight == newHeight
                && oldDuration == newDuration
                && oldFilename == newFilename
                && oldMime == newMime
                && oldSize == newSize
                && oldCaption == newCaption
                && oldPreview == newPreview
        case (.file(_, let oldFilename, let oldMime, let oldSize, let oldCaption),
              .file(_, let newFilename, let newMime, let newSize, let newCaption)):
            return oldFilename == newFilename
                && oldMime == newMime
                && oldSize == newSize
                && oldCaption == newCaption
        default:
            return old.content == new.content
        }
    }

    private static func isVisuallyEquivalentCompositeMediaGroupRow(old: ChatMessage, new: ChatMessage) -> Bool {
        guard let oldPresentation = old.mediaGroupPresentation,
              let newPresentation = new.mediaGroupPresentation,
              oldPresentation.rendersCompositeBubble,
              newPresentation.rendersCompositeBubble,
              oldPresentation.id == newPresentation.id
        else {
            return false
        }
        return true
    }

    private static func mediaGroupPresentationIsVisuallyEquivalent(
        old: MediaGroupPresentation?,
        new: MediaGroupPresentation?
    ) -> Bool {
        switch (old, new) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            if lhs.rendersCompositeBubble && rhs.rendersCompositeBubble {
                return lhs.id == rhs.id
                    && lhs.position == rhs.position
                    && lhs.totalHint == rhs.totalHint
                    && lhs.caption == rhs.caption
                    && lhs.captionPlacement == rhs.captionPlacement
                    && lhs.layoutOverride == rhs.layoutOverride
                    && lhs.suppressIndividualCaption == rhs.suppressIndividualCaption
                    && lhs.rendersCompositeBubble == rhs.rendersCompositeBubble
                    && lhs.hidesStandaloneBubble == rhs.hidesStandaloneBubble
                    && lhs.items.count == rhs.items.count
            }

            guard lhs.id == rhs.id,
                  lhs.position == rhs.position,
                  lhs.totalHint == rhs.totalHint,
                  lhs.caption == rhs.caption,
                  lhs.captionPlacement == rhs.captionPlacement,
                  lhs.suppressIndividualCaption == rhs.suppressIndividualCaption,
                  lhs.rendersCompositeBubble == rhs.rendersCompositeBubble,
                  lhs.hidesStandaloneBubble == rhs.hidesStandaloneBubble
            else {
                return false
            }

            guard lhs.items.count == rhs.items.count else { return false }
            return zip(lhs.items, rhs.items).allSatisfy { oldItem, newItem in
                oldItem.sourceURL == newItem.sourceURL
                    && oldItem.previewIdentity == newItem.previewIdentity
                    && oldItem.width == newItem.width
                    && oldItem.height == newItem.height
                    && oldItem.caption == newItem.caption
            }
        default:
            return false
        }
    }

    /// Incoming messages never expose a send-status indicator, even if
    /// their storage row carries a transport state like "synced".
    func statusIcon(forSendStatus status: String) -> MessageStatusIcon? {
        guard isOutgoing else { return nil }
        return MessageStatusIcon.from(sendStatus: status)
    }

    /// Update send-status icon without recreating the cell.
    func updateSendStatus(_ status: String) {
        guard let iconNode = statusIconNode,
              let newIcon = statusIcon(forSendStatus: status)
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

    // MARK: - Paint Splash

    func paintSplashTarget(
        frameInScreen overrideFrameInScreen: CGRect? = nil
    ) -> PaintSplashTrigger.SnapshotTarget? {
        let sourceView = bubbleWrapperNode.view
        guard sourceView.bounds.width > 0, sourceView.bounds.height > 0 else {
            return nil
        }

        let image = UIGraphicsImageRenderer(bounds: sourceView.bounds).image { ctx in
            BubblePortalCaptureRenderer.renderLayerForCapture(
                sourceView.layer,
                in: ctx.cgContext,
                clipRectInLayer: sourceView.bounds
            )
        }

        guard image.cgImage != nil else { return nil }

        return PaintSplashTrigger.SnapshotTarget(
            sourceView: sourceView,
            frameInScreen: overrideFrameInScreen ?? sourceView.convert(
                sourceView.bounds,
                to: sourceView.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
            ),
            image: image,
            hideSource: { [weak self] in self?.alpha = 0 }
        )
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

    func assignProbeName(_ name: String, to node: ASDisplayNode) {
        if node.isNodeLoaded {
            node.layer.name = name
        } else {
            node.onDidLoad { loadedNode in
                loadedNode.layer.name = name
            }
        }
    }

    fileprivate func assignProbeLayerNames() {
        assignProbeName("message.contextSource", to: contextSourceNode)
        assignProbeName("message.bubbleWrapper", to: bubbleWrapperNode)
        assignProbeName("message.bubbleFallbackBackground", to: bubbleBackgroundNode)
        assignProbeName("message.bubblePortalBackground", to: bubblePortalBackgroundNode)
        assignProbeName("message.bubbleNode", to: bubbleNode)
        assignProbeName("message.directBubbleContent", to: directBubbleContentNode)
        assignProbeName("message.timeNode", to: timeNode)
        assignProbeName("message.senderName", to: senderNameNode)
        assignProbeName("message.avatarBackground", to: avatarBackgroundNode)
        assignProbeName("message.avatarImage", to: avatarImageNode)

        if let reactionsNode {
            assignProbeName("message.reactions", to: reactionsNode)
        }
        if let replyHeaderNode {
            assignProbeName("message.replyHeader", to: replyHeaderNode)
        }
        if let forwardedHeaderNode {
            assignProbeName("message.forwardedHeader", to: forwardedHeaderNode)
        }
    }
}
