//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

struct Message: Equatable {
    let sentByMe: Bool
    let text: String
}

final class ChatCellNode: ASCellNode {
    
    private let messageTextNode = ASTextNode()
    private let isSentByMe: Bool
    private let bubbleNode = ASDisplayNode()
    
    init(message: Message, screenWidth: CGFloat) {
        self.isSentByMe = message.sentByMe
        super.init()
        
        automaticallyManagesSubnodes = true
        selectionStyle = .none

        messageTextNode.attributedText = NSAttributedString(
            string: message.text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.white
            ]
        )
        
        messageTextNode.style.maxWidth = ASDimension(unit: .points, value: screenWidth / 1.18)
        
        bubbleNode.backgroundColor = isSentByMe ? .systemBlue : .systemGray4
        bubbleNode.cornerRadius = 16
        bubbleNode.clipsToBounds = true
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let bubbleInset: CGFloat = 12
        
        let textInsetSpec = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 8, left: bubbleInset, bottom: 8, right: bubbleInset),
            child: messageTextNode
        )
        
        let bubbleWrapper = ASBackgroundLayoutSpec(
            child: textInsetSpec,
            background: bubbleNode
        )
        
        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let hStack = ASStackLayoutSpec.horizontal()
        hStack.spacing = 4
        hStack.alignItems = .start
        hStack.children = isSentByMe
            ? [spacer, bubbleWrapper]
            : [bubbleWrapper, spacer]

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8),
            child: hStack
        )
    }
}
