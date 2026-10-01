// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

final class RoomProfileTextCell: ASCellNode {
    init(title: String, detail: String? = nil, isHeader: Bool = false, isAction: Bool = false) {
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
            .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: UIColor.secondaryLabel
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

final class RoomProfileHeaderNode: ASDisplayNode {
    let avatar = ASImageNode()
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let titleText: String
    private let subtitleText: String

    init(title: String, subtitle: String) {
        titleText = title
        subtitleText = subtitle
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .appBG
        avatar.style.preferredSize = CGSize(width: 88, height: 88)
        avatar.cornerRadius = 44
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        updateTypography()
        titleNode.maximumNumberOfLines = 2
        subtitleNode.maximumNumberOfLines = 2
        titleNode.accessibilityTraits = .header
    }

    func updateTypography() {
        titleNode.attributedText = NSAttributedString(string: titleText, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .title2), .foregroundColor: UIColor.label
        ])
        subtitleNode.attributedText = NSAttributedString(string: subtitleText, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.secondaryLabel
        ])
        setNeedsLayout()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let stack = ASStackLayoutSpec.vertical()
        stack.spacing = 8
        stack.alignItems = .center
        stack.children = [avatar, titleNode, subtitleNode]
        return ASInsetLayoutSpec(insets: UIEdgeInsets(top: 12, left: 24, bottom: 16, right: 24), child: stack)
    }
}
