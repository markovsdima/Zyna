//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class GradientButton: BaseNode {
    let button: ButtonNode
    private let gradient: GradientNode
    
    init(title: String, gradientStyle: GradientNodeStyle) {
        self.button = ButtonNode(title: title)
        self.gradient = GradientNode(nodeStyle: gradientStyle)
        super.init()
        self.cornerRadius = 16
        self.cornerRoundingType = .clipping
    }
    
    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        return ASBackgroundLayoutSpec(
            child: button,
            background: gradient
        )
    }
    
    override func layout() {
        super.layout()
        gradient.frame = self.bounds
    }
}
