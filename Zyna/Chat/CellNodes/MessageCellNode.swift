//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Base class for all message cell nodes.
/// Handles context menu protocol, sender name, bubble styling, and the outer layout.
class MessageCellNode: ZynaCellNode, ContextMenuCellNode {

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

    // MARK: - Reply

    var onReplyHeaderTapped: ((String) -> Void)?
    private(set) var replyHeaderNode: ReplyHeaderNode?
    private(set) var forwardedHeaderNode: ASTextNode?


    // MARK: - Subnodes

    let bubbleNode = RoundedBackgroundNode()
    let contextSourceNode: ContextSourceNode
    let timeNode = ASTextNode()
    let statusIconNode: MessageStatusIconNode?
    let senderNameNode = ASTextNode()
    private(set) var reactionsNode: ReactionsNode?

    // MARK: - State

    let isOutgoing: Bool
    let showSenderName: Bool

    private let accessibilityContent: String

    // MARK: - Init

    init(message: ChatMessage, isGroupChat: Bool = false) {
        var parts: [String] = []
        if let sender = message.senderDisplayName, !message.isOutgoing {
            parts.append(sender)
        }
        parts.append(message.content.textPreview)
        parts.append(MessageCellHelpers.timeFormatter.string(from: message.timestamp))
        self.accessibilityContent = parts.joined(separator: ", ")

        self.isOutgoing = message.isOutgoing
        self.showSenderName = !message.isOutgoing && isGroupChat
        self.contextSourceNode = ContextSourceNode(contentNode: bubbleNode)

        // Status icon only on the sender's own bubbles. For incoming
        // messages it carries no information and would just clutter.
        if message.isOutgoing,
           let iconState = MessageStatusIcon.from(sendStatus: message.sendStatus) {
            let node = MessageStatusIconNode()
            node.icon = iconState
            node.tintColour = AppColor.bubbleTimestampOutgoing
            self.statusIconNode = node
        } else {
            self.statusIconNode = nil
        }
        super.init()

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = accessibilityContent

        contextSourceNode.activated = { [weak self] _ in
            self?.onContextMenuActivated?()
        }

        automaticallyManagesSubnodes = true
        selectionStyle = .none
        // ASCellNode is wrapped in a UITableViewCell whose default
        // backgroundColor (.systemBackground) would otherwise occlude
        // the table's own background and break glass backdrop sampling.
        backgroundColor = .clear

        // Bubble defaults — custom color from Zyna attributes wins if set.
        let customColor = message.zynaAttributes.color
        bubbleNode.fillColor = customColor
            ?? (isOutgoing ? AppColor.bubbleBackgroundOutgoing
                           : AppColor.bubbleBackgroundIncoming)
        bubbleNode.radius = 18
        bubbleNode.automaticallyManagesSubnodes = true

        // Timestamp (default colors — override in subclass if needed)
        timeNode.attributedText = NSAttributedString(
            string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: isOutgoing
                    ? AppColor.bubbleTimestampOutgoing
                    : AppColor.bubbleTimestampIncoming
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
        }

        // Forwarded header
        if let forwarderName = message.zynaAttributes.forwardedFrom {
            let node = ASTextNode()
            node.attributedText = NSAttributedString(
                string: "↗ " + String(localized: "Forwarded from \(forwarderName)"),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: isOutgoing
                        ? AppColor.bubbleTimestampOutgoing
                        : UIColor.secondaryLabel
                ]
            )
            node.maximumNumberOfLines = 1
            self.forwardedHeaderNode = node
        }

        // Reply header
        if let replyInfo = message.replyInfo {
            let rh = ReplyHeaderNode(replyInfo: replyInfo, isOutgoing: isOutgoing)
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

        // Reactions
        if !message.reactions.isEmpty {
            let rNode = ReactionsNode(reactions: message.reactions)
            rNode.onReactionTapped = { [weak self] key in
                self?.onReactionTapped?(key)
            }
            rNode.style.maxWidth = ASDimension(
                unit: .points,
                value: ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
            )
            self.reactionsNode = rNode
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        hStack.children = isOutgoing
            ? [spacer, column]
            : [column, spacer]

        return ASInsetLayoutSpec(insets: MessageCellHelpers.cellInsets, child: hStack)
    }

    // MARK: - In-Place Update

    /// Returns true if the change between old and new can be applied
    /// without recreating the cell (only send-status changed).
    static func canUpdateInPlace(old: ChatMessage, new: ChatMessage) -> Bool {
        old.id == new.id
            && old.content == new.content
            && old.reactions == new.reactions
            && old.zynaAttributes == new.zynaAttributes
            && old.replyInfo == new.replyInfo
            && old.senderDisplayName == new.senderDisplayName
    }

    /// Update send-status icon without recreating the cell.
    func updateSendStatus(_ status: String) {
        guard let iconNode = statusIconNode,
              let newIcon = MessageStatusIcon.from(sendStatus: status)
        else { return }
        iconNode.icon = newIcon
    }

    // MARK: - Highlight

    func highlightBubble() {
        guard isNodeLoaded else { return }
        let highlight = CAShapeLayer()
        highlight.frame = bubbleNode.bounds
        highlight.path = bubbleNode.currentPath().cgPath
        highlight.fillColor = (isOutgoing ? AppColor.bubbleForegroundOutgoing : AppColor.bubbleForegroundIncoming)
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
