//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ChatNode: ASDisplayNode {
    let tableNode = ASTableNode()
    let inputNode = ChatInputNode()

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        tableNode.inverted = true
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let tableSpec = ASWrapperLayoutSpec(layoutElement: tableNode)
        tableSpec.style.flexGrow = 1

        let stack = ASStackLayoutSpec.vertical()
        stack.children = [tableSpec, inputNode]

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 0, bottom: safeAreaInsets.bottom, right: 0),
            child: stack
        )
    }
}
