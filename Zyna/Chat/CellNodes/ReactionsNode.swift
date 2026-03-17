//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ReactionsNode: ASDisplayNode {

    var onReactionTapped: ((String) -> Void)?

    private let reactions: [MessageReaction]
    private var pillNodes: [ReactionPillNode] = []

    init(reactions: [MessageReaction]) {
        self.reactions = reactions
        super.init()
        automaticallyManagesSubnodes = true

        for reaction in reactions {
            let pill = ReactionPillNode(reaction: reaction)
            pill.addTarget(self, action: #selector(pillTapped(_:)), forControlEvents: .touchUpInside)
            pillNodes.append(pill)
        }
    }

    @objc private func pillTapped(_ sender: ReactionPillNode) {
        onReactionTapped?(sender.reactionKey)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let flowLayout = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 4,
            justifyContent: .start,
            alignItems: .center,
            flexWrap: .wrap,
            alignContent: .start,
            lineSpacing: 4,
            children: pillNodes
        )
        return flowLayout
    }
}

// MARK: - Reaction Pill

final class ReactionPillNode: ASControlNode {

    let reactionKey: String
    private let labelNode = ASTextNode()

    init(reaction: MessageReaction) {
        self.reactionKey = reaction.key
        super.init()
        automaticallyManagesSubnodes = true

        let countText = reaction.count > 1 ? " \(reaction.count)" : ""
        let text = "\(reaction.key)\(countText)"

        labelNode.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: reaction.isOwn ? UIColor.systemBlue : UIColor.label
            ]
        )

        backgroundColor = reaction.isOwn ? UIColor.systemBlue.withAlphaComponent(0.12) : .systemGray5
        cornerRadius = 13
        if reaction.isOwn {
            borderWidth = 1
            borderColor = UIColor.systemBlue.withAlphaComponent(0.4).cgColor
        }

        style.minHeight = ASDimension(unit: .points, value: 26)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8),
            child: labelNode
        )
    }
}
