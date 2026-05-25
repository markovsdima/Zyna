//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceScreenNode: ScreenNode {
    weak var glassTopBar: GlassTopBar?
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
            AccessibilityElementOrder.appendProvider(
                glassTopBar,
                fallbackView: glassTopBar?.view,
                to: &elements
            )
            AccessibilityElementOrder.appendVisibleView(tableNode.view, to: &elements)
            return elements
        }
        set { }
    }
}
