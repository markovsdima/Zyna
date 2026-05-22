//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceLinesPlaceholderCellNode: ZynaCellNode {
    private let textNode = ASTextNode()
    private let separatorNode = ASDisplayNode()

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .systemBackground

        textNode.attributedText = NSAttributedString(
            string: String(localized: "Directions within this Storyline will appear here."),
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        textNode.maximumNumberOfLines = 0
        separatorNode.backgroundColor = UIColor.separator
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let content = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 12, left: 16, bottom: 14, right: 16),
            child: textNode
        )

        separatorNode.style.preferredSize = CGSize(width: constrainedSize.max.width, height: 0.5)
        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [content, separatorNode]
        )
    }
}
