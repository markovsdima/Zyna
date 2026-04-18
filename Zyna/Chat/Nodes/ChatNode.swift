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
            elements.append(tableNode.view)
            return elements
        }
        set { }
    }
}
