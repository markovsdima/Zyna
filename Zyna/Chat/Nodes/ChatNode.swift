//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ChatNode: ASDisplayNode {
    let tableNode = ASTableNode()

    override init() {
        super.init()
        addSubnode(tableNode)
        tableNode.inverted = true
        backgroundColor = AppColor.chatBackground
        tableNode.backgroundColor = AppColor.chatBackground
    }

    override func layout() {
        super.layout()
        tableNode.frame = bounds
    }
}
