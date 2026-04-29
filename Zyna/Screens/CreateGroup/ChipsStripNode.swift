//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ChipsStripNode: ASScrollNode {

    private var chipNodes: [SelectedUserChipNode] = []

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        automaticallyManagesContentSize = true
        scrollableDirections = [.left, .right]
    }

    override func didLoad() {
        super.didLoad()
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        // Horizontal scroll views are auto-detected by our back-swipe
        // guard, but pin the flag for intent clarity.
        view.disablesInteractiveTransitionGestureRecognizer = true
    }

    func setUsers(_ users: [UserProfile], onRemove: @escaping (UserProfile) -> Void) {
        let existing = Dictionary(
            chipNodes.map { ($0.userId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        chipNodes = users.map { user in
            let chip = existing[user.userId] ?? SelectedUserChipNode(user: user)
            chip.onRemove = { onRemove(user) }
            return chip
        }
        setNeedsLayout()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let stack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .center,
            children: chipNodes
        )
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16),
            child: stack
        )
    }
}
