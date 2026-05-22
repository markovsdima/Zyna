//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceEmptyChatsCellNode: ZynaCellNode {
    private let textNode = ASTextNode()

    init(message: String) {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .systemBackground

        textNode.attributedText = NSAttributedString(
            string: message,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        textNode.maximumNumberOfLines = 0
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 18, left: 16, bottom: 18, right: 16),
            child: textNode
        )
    }
}
