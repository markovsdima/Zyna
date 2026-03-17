//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Base class for all message cell nodes.
/// Handles context menu protocol, sender name, bubble styling, and the outer layout.
class MessageCellNode: ASCellNode, ContextMenuCellNode {

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

    // MARK: - Subnodes

    let bubbleNode = ASDisplayNode()
    let contextSourceNode: ContextSourceNode
    let timeNode = ASTextNode()
    let senderNameNode = ASTextNode()
    private(set) var reactionsNode: ReactionsNode?

    // MARK: - State

    let isOutgoing: Bool
    let showSenderName: Bool

    // MARK: - Init

    init(message: ChatMessage, isGroupChat: Bool = false) {
        self.isOutgoing = message.isOutgoing
        self.showSenderName = !message.isOutgoing && isGroupChat
        self.contextSourceNode = ContextSourceNode(contentNode: bubbleNode)
        super.init()

        contextSourceNode.activated = { [weak self] _ in
            self?.onContextMenuActivated?()
        }

        automaticallyManagesSubnodes = true
        selectionStyle = .none

        // Bubble defaults
        bubbleNode.backgroundColor = isOutgoing ? .systemBlue : .systemGray5
        bubbleNode.cornerRadius = 18
        bubbleNode.clipsToBounds = true
        bubbleNode.automaticallyManagesSubnodes = true

        // Timestamp (default colors — override in subclass if needed)
        timeNode.attributedText = NSAttributedString(
            string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: isOutgoing
                    ? UIColor.white.withAlphaComponent(0.7)
                    : UIColor.secondaryLabel
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

    // MARK: - Context Menu Reparenting

    func extractBubbleForMenu(in coordinateSpace: UICoordinateSpace) -> (node: ASDisplayNode, frame: CGRect)? {
        guard isNodeLoaded else { return nil }
        return contextSourceNode.extractContentForMenu(in: coordinateSpace)
    }

    func restoreBubbleFromMenu() {
        contextSourceNode.restoreContentFromMenu()
    }
}
