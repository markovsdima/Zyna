//
//  TextInputNode.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 21.04.2025.
//

import AsyncDisplayKit

final class TextInputNode: BaseNode {
    
    enum FieldType {
        case regular
        case email
        case password
    }
    
    private let textNode: ASEditableTextNode
    private let backgroundNode: ASDisplayNode
    private let placeholder: String?
    private let type: FieldType
    
    var text: String {
        textNode.attributedText?.string ?? ""
    }
    
    init(placeholder: String?, type: FieldType) {
        self.textNode = ASEditableTextNode()
        self.backgroundNode = ASDisplayNode()
        self.placeholder = placeholder
        self.type = type
        super.init()
        setupUI()
    }
    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let backgroundInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10),
            child: textNode
        )
        
        let backgroundSpec = ASBackgroundLayoutSpec(
            child: backgroundInset,
            background: backgroundNode
        )
        
        return backgroundSpec
    }
    private func setupUI() {
        // Keyboard & secure settings
        switch type {
        case .email:
            textNode.keyboardType = .emailAddress
            textNode.autocapitalizationType = .none
        case .password:
            textNode.textView.isSecureTextEntry = true
        case .regular:
            break
        }
        
        // TextNode style
        textNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 24),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.textInput
        ]
        
        //        textNode.attributedText = NSAttributedString(
        //            string: placeholder ?? "",
        //            attributes: [
        //                .font: UIFont.systemFont(ofSize: 16),
        //                .foregroundColor: UIColor(white: 0.75, alpha: 1)
        //            ]
        //        )
        textNode.style.flexGrow = 1.0
        //textNode.style.height = ASDimension(unit: .points, value: 44)
        textNode.textView.backgroundColor = .clear
        textNode.textView.isScrollEnabled = false
        textNode.textView.tintColor = .black
        textNode.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        
        // Placeholder
        textNode.attributedPlaceholderText = NSAttributedString(
            string: placeholder ?? "",
            attributes: [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.textInputPlaceholder
            ]
        )
        
        // Background style
        backgroundNode.backgroundColor = .textInputBG
        backgroundNode.cornerRadius = 8
        
        //backgroundNode.cornerRoundingType = .precomposited
        backgroundNode.clipsToBounds = true
        backgroundNode.style.height = ASDimension(unit: .points, value: 44)
        //addSubnode(backgroundNode)
        //addSubnode(textNode)
    }
}
