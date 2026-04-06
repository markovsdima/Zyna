//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class TextInputNode: ASDisplayNode {
    
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
        automaticallyManagesSubnodes = true
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
    override func didLoad() {
        super.didLoad()

        // UIView access is safe here (main thread, view loaded)
        switch type {
        case .password:
            textNode.textView.isSecureTextEntry = true
        default:
            break
        }
        textNode.textView.backgroundColor = .clear
        textNode.textView.isScrollEnabled = false
        textNode.textView.tintColor = .black
    }

    private func setupUI() {
        // Keyboard settings (proxy properties — safe in init)
        switch type {
        case .email:
            textNode.keyboardType = .emailAddress
            textNode.autocapitalizationType = .none
        default:
            break
        }

        // TextNode style
        textNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 24),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.textInput
        ]
        textNode.style.flexGrow = 1.0
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
        backgroundNode.clipsToBounds = true
        backgroundNode.style.height = ASDimension(unit: .points, value: 44)
    }
}
