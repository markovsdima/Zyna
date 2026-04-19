//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SelectMembersNode: ScreenNode {

    let tableNode = ASTableNode()
    let headerNode = SelectMembersHeaderNode()
    let chipsStripNode = ChipsStripNode()

    private let chipsStripHeight: CGFloat = 44

    var showChips = false {
        didSet {
            guard showChips != oldValue else { return }
            setNeedsLayout()
        }
    }

    override init() {
        super.init()
        // Manual frame layout — layoutSpec + dynamic children misbehaves
        // with ASTableNode (rows blank after transition).
        automaticallyManagesSubnodes = false
        automaticallyRelayoutOnSafeAreaChanges = true
        tableNode.backgroundColor = .appBG

        addSubnode(headerNode)
        addSubnode(chipsStripNode)
        addSubnode(tableNode)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }

        let headerSize = headerNode.layoutThatFits(
            ASSizeRange(
                min: CGSize(width: width, height: 0),
                max: CGSize(width: width, height: .infinity)
            )
        ).size
        headerNode.frame = CGRect(x: 0, y: 0, width: width, height: headerSize.height)

        let chipsH = showChips ? chipsStripHeight : 0
        chipsStripNode.frame = CGRect(x: 0, y: headerSize.height, width: width, height: chipsH)

        let tableTop = headerSize.height + chipsH
        tableNode.frame = CGRect(
            x: 0,
            y: tableTop,
            width: width,
            height: max(0, bounds.height - tableTop)
        )
    }
}
