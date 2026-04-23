//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class SelectedUserChipNode: ASDisplayNode {

    let userId: String
    var onRemove: (() -> Void)?

    private let nameNode = ASTextNode()
    private let removeNode = ASImageNode()
    private let backgroundNode = ASDisplayNode()

    init(user: UserProfile) {
        self.userId = user.userId
        super.init()
        automaticallyManagesSubnodes = true

        let name = user.displayName ?? String(user.userId.prefix(10))

        backgroundNode.backgroundColor = .systemGray5
        backgroundNode.cornerRadius = 16

        nameNode.attributedText = NSAttributedString(
            string: name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.label
            ]
        )
        nameNode.maximumNumberOfLines = 1

        removeNode.image = UIImage(systemName: "xmark.circle.fill")?
            .withTintColor(.systemGray2, renderingMode: .alwaysOriginal)
        removeNode.style.preferredSize = CGSize(width: 18, height: 18)
    }

    override func didLoad() {
        super.didLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        view.addGestureRecognizer(tap)
    }

    @objc private func tapped() {
        onRemove?()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 4,
            justifyContent: .start,
            alignItems: .center,
            children: [nameNode, removeNode]
        )

        let padded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 8),
            child: row
        )

        return ASBackgroundLayoutSpec(child: padded, background: backgroundNode)
    }
}
