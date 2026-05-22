//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceScreenNode: ScreenNode {
    weak var glassTopBar: ASDisplayNode?
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

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar?.view, bar.superview === view {
                elements.append(bar)
            }
            elements.append(tableNode.view)
            return elements
        }
        set { }
    }
}
