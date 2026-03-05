//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ChatInputNode: ASDisplayNode {

    let textInputNode = ASEditableTextNode()
    let sendButtonNode = ASButtonNode()
    let attachButtonNode = ASButtonNode()
    private let separatorNode = ASDisplayNode()

    var onSend: ((String) -> Void)?

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
    }

    private func setupNodes() {
        separatorNode.style.height = ASDimension(unit: .points, value: 0.5)
        separatorNode.backgroundColor = .separator

        textInputNode.textView.font = .systemFont(ofSize: 16)
        textInputNode.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        textInputNode.style.flexGrow = 1
        textInputNode.style.minHeight = ASDimension(unit: .points, value: 36)
        textInputNode.style.maxHeight = ASDimension(unit: .points, value: 120)
        textInputNode.scrollEnabled = true

        textInputNode.backgroundColor = .secondarySystemBackground
        textInputNode.cornerRadius = 18

        let attachConfig = UIImage.SymbolConfiguration(pointSize: 22)
        attachButtonNode.setImage(
            UIImage(systemName: "paperclip", withConfiguration: attachConfig),
            for: .normal
        )
        attachButtonNode.style.preferredSize = CGSize(width: 36, height: 36)

        let sendConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        sendButtonNode.setImage(
            UIImage(systemName: "arrow.up.circle.fill", withConfiguration: sendConfig),
            for: .normal
        )
        sendButtonNode.tintColor = .systemBlue
        sendButtonNode.style.preferredSize = CGSize(width: 36, height: 36)
    }

    // MARK: - didLoad
    // тут можно трогать .view

    override func didLoad() {
        super.didLoad()
        backgroundColor = .systemBackground
        textInputNode.delegate = self
        sendButtonNode.addTarget(self, action: #selector(sendTapped), forControlEvents: .touchUpInside)
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Кнопки прижаты к низу (когда поле растягивается на несколько строк)
        let attachSpec = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .end,
            alignItems: .center,
            children: [attachButtonNode]
        )
        let sendSpec = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .end,
            alignItems: .center,
            children: [sendButtonNode]
        )

        // Горизонтальный стек: [attach] [input] [send]
        let inputRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .end,
            children: [attachSpec, textInputNode, sendSpec]
        )

        let paddedRow = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8),
            child: inputRow
        )

        // Separator + input row
        let fullStack = ASStackLayoutSpec.vertical()
        fullStack.children = [separatorNode, paddedRow]

        return fullStack
    }

    // MARK: - Actions

    @objc private func sendTapped() {
        let text = textInputNode.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend?(text)
        textInputNode.textView.text = ""
        setNeedsLayout()
    }
}

// MARK: - ASEditableTextNodeDelegate

extension ChatInputNode: ASEditableTextNodeDelegate {
    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        // Текст изменился — пересчитать layout (высота поля)
        setNeedsLayout()
    }
}
