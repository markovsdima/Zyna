//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Base class for centered system-event cells (calls, room changes,
/// membership events, etc.). Subclasses provide the attributed text;
/// layout and styling are handled here.
class SystemEventCellNode: ASCellNode {

    let labelNode = ASTextNode()

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let centered = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: .minimumXY,
            child: labelNode
        )
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16),
            child: centered
        )
    }
}
