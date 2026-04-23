//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SettingsViewController: ASDKViewController<ASDisplayNode> {

    private let textNode = ASTextNode()

    override init() {
        super.init(node: ScreenNode())

        textNode.attributedText = NSAttributedString(
            string: String(localized: "Settings"),
            attributes: [
                .font: UIFont.boldSystemFont(ofSize: 24),
                .foregroundColor: UIColor.black
            ]
        )

        node.layoutSpecBlock = { [weak self] _, _ in
            guard let self = self else { return ASLayoutSpec() }
            return ASCenterLayoutSpec(
                centeringOptions: .XY,
                sizingOptions: [],
                child: self.textNode
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
