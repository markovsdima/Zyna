// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

final class RoomProfileTextCell: ASCellNode {
    init(title: String, detail: String? = nil, isHeader: Bool = false, isAction: Bool = false, isError: Bool = false) {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .appBG
        let titleNode = ASTextNode()
        titleNode.attributedText = NSAttributedString(string: title, attributes: [
            .font: UIFont.preferredFont(forTextStyle: isHeader ? .subheadline : .body),
            .foregroundColor: isAction ? UIColor.systemBlue : UIColor.label
        ])
        titleNode.maximumNumberOfLines = isHeader ? 1 : 2
        let detailNode = ASTextNode()
        detailNode.attributedText = NSAttributedString(string: detail ?? "", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .caption1),
            .foregroundColor: isError ? UIColor.systemRed : UIColor.secondaryLabel
        ])
        detailNode.maximumNumberOfLines = 3
        layoutSpecBlock = { _, _ in
            let stack = ASStackLayoutSpec.vertical()
            stack.spacing = 5
            stack.children = detail == nil ? [titleNode] : [titleNode, detailNode]
            return ASInsetLayoutSpec(insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16), child: stack)
        }
        isAccessibilityElement = true
        accessibilityLabel = [title, detail].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = isHeader ? .header : (isAction ? .button : .staticText)
    }
}
