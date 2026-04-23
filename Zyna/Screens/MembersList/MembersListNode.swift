//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class MembersListNode: ScreenNode {

    let tableNode = ASTableNode()
    weak var glassTopBar: GlassTopBar?

    override init() {
        super.init()
        tableNode.backgroundColor = .systemBackground
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASWrapperLayoutSpec(layoutElement: tableNode)
    }

    /// Bar before the table so VoiceOver doesn't get swallowed by the
    /// table's cells. Same pattern as RoomsScreenNode.
    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar, bar.view.superview === view {
                elements.append(contentsOf: bar.accessibilityElementsInOrder)
            }
            elements.append(tableNode.view)
            return elements
        }
        set { }
    }
}
