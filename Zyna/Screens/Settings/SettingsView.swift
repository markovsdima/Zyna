//
//  SettingsView.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 04.07.2025.
//

import AsyncDisplayKit
import RxFlow
import RxRelay

final class SettingsViewController: ASDKViewController<ASDisplayNode>, Stepper {
    
    let steps = PublishRelay<Step>()
    private let textNode = ASTextNode()
    
    override init() {
        super.init(node: BaseNode())
        
        textNode.attributedText = NSAttributedString(
            string: "Настройки",
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
