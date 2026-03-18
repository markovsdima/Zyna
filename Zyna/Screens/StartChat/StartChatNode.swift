//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class StartChatNode: BaseNode {

    let tableNode = ASTableNode()

    override init() {
        super.init()
        tableNode.backgroundColor = .appBG
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASWrapperLayoutSpec(layoutElement: tableNode)
    }
}
