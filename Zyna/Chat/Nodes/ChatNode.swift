//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ChatNode: ASDisplayNode {
    let tableNode = ASTableNode()

    /// Set by ChatViewController. Used to put glass bars first in the
    /// accessibility tree so VoiceOver hit-tests the bars before the
    /// table cells visually behind them (the bars are transparent glass).
    weak var glassNavBar: ASDisplayNode?
    weak var glassInputBar: ASDisplayNode?

    /// Set by ChatViewController. The scroll-to-live floating button lives
    /// at this node's view level (not inside the input bar) so its tap
    /// target works when positioned above the bar's bounds.
    weak var scrollButtonTap: UIView?

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

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let nav = glassNavBar?.view, nav.superview === view {
                elements.append(nav)
            }
            if let input = glassInputBar?.view, input.superview === view {
                elements.append(input)
            }
            if let tap = scrollButtonTap, tap.superview === view, tap.alpha > 0 {
                elements.append(tap)
            }
            elements.append(tableNode.view)
            return elements
        }
        set { }
    }
}
