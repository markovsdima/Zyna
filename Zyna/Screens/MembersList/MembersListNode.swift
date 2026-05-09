//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class MembersListNode: ScreenNode {

    let tableNode = ASTableNode()
    weak var voicePlayerView: UIView?
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
            if let player = voicePlayerView,
               player.superview === view,
               !player.isHidden,
               player.alpha > 0.01 {
                elements.append(player)
            }
            if let bar = glassTopBar, bar.view.superview === view {
                elements.append(contentsOf: bar.accessibilityElementsInOrder)
            }
            elements.append(tableNode.view)
            return elements
        }
        set { }
    }
}
