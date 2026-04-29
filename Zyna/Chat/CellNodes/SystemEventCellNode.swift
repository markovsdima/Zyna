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
    private let pillNode = RoundedBackgroundNode()

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none
        // UITableViewCell's default `.systemBackground` would otherwise
        // occlude the chat's own background and break glass backdrop sampling.
        backgroundColor = .clear

        pillNode.fillColor = AppColor.systemEventBackground
        pillNode.radius = 10
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let labelPadded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10),
            child: labelNode
        )
        let pill = ASBackgroundLayoutSpec(child: labelPadded, background: pillNode)
        let centered = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: .minimumXY,
            child: pill
        )
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16),
            child: centered
        )
    }
}

final class DateDividerCellNode: ZynaCellNode {
    static let height: CGFloat = 34

    private let spacerNode = ASDisplayNode()

    init(model: DateDividerModel) {
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none
        backgroundColor = .clear
        spacerNode.isLayerBacked = true
        spacerNode.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = model.title
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let width = constrainedSize.max.width.isFinite ? max(1, constrainedSize.max.width) : 1
        spacerNode.style.preferredSize = CGSize(
            width: width,
            height: Self.height
        )
        return ASWrapperLayoutSpec(layoutElement: spacerNode)
    }
}
