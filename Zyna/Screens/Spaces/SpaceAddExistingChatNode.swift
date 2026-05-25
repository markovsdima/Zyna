//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceAddExistingChatNode: ScreenNode {

    let tableNode = ASTableNode(style: .plain)

    override init() {
        super.init()
        automaticallyManagesSubnodes = false
        backgroundColor = .systemBackground
        tableNode.backgroundColor = .systemBackground
        addSubnode(tableNode)
    }

    override func layout() {
        super.layout()
        tableNode.frame = bounds
    }
}
