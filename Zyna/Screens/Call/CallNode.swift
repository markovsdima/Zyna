//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

// MARK: - Call Node

final class CallNode: ASDisplayNode {

    let nameLabel = ASTextNode()
    let statusLabel = ASTextNode()
    let avatarNode = ASDisplayNode()

    let acceptButton = ASButtonNode()
    let muteButton = ASButtonNode()
    let speakerButton = ASButtonNode()
    let endCallButton = ASButtonNode()

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
    }

    private func setupNodes() {
        // Avatar placeholder
        avatarNode.style.preferredSize = CGSize(width: 100, height: 100)
        avatarNode.cornerRadius = 50
        avatarNode.backgroundColor = .systemGray4

        // Name
        nameLabel.maximumNumberOfLines = 1

        // Status
        statusLabel.maximumNumberOfLines = 1

        // Accept button (hidden by default, shown for incoming calls)
        acceptButton.setImage(Self.symbol("phone.fill", size: 24, color: .white), for: .normal)
        acceptButton.style.preferredSize = CGSize(width: 70, height: 70)
        acceptButton.cornerRadius = 35
        acceptButton.backgroundColor = .systemGreen
        acceptButton.isHidden = true

        // Mute button
        muteButton.setImage(Self.symbol("mic.fill", size: 24, color: .white), for: .normal)
        muteButton.setImage(Self.symbol("mic.slash.fill", size: 24, color: .white), for: .selected)
        muteButton.style.preferredSize = CGSize(width: 60, height: 60)
        muteButton.cornerRadius = 30
        muteButton.backgroundColor = .systemGray

        // Speaker button
        speakerButton.setImage(Self.symbol("speaker.wave.2.fill", size: 24, color: .white), for: .normal)
        speakerButton.setImage(Self.symbol("speaker.wave.3.fill", size: 24, color: .white), for: .selected)
        speakerButton.style.preferredSize = CGSize(width: 60, height: 60)
        speakerButton.cornerRadius = 30
        speakerButton.backgroundColor = .systemGray

        // End call button
        endCallButton.setImage(Self.symbol("phone.down.fill", size: 24, color: .white), for: .normal)
        endCallButton.style.preferredSize = CGSize(width: 70, height: 70)
        endCallButton.cornerRadius = 35
        endCallButton.backgroundColor = .systemRed
    }

    // MARK: - Update

    func updateName(_ name: String) {
        nameLabel.attributedText = NSAttributedString(
            string: name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
    }

    func updateStatus(_ status: String) {
        statusLabel.attributedText = NSAttributedString(
            string: status,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Top section: avatar + name + status
        let topStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 12,
            justifyContent: .center,
            alignItems: .center,
            children: [avatarNode, nameLabel, statusLabel]
        )

        // Bottom section: action buttons
        var buttons: [ASLayoutElement] = []
        if !acceptButton.isHidden {
            buttons = [endCallButton, acceptButton]
        } else {
            buttons = [muteButton, endCallButton, speakerButton]
        }

        let buttonsStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 32,
            justifyContent: .center,
            alignItems: .center,
            children: buttons
        )

        // Spacer between top and bottom
        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let mainStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .center,
            children: [topStack, spacer, buttonsStack]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 80, left: 24, bottom: 60, right: 24),
            child: mainStack
        )
    }

    // MARK: - Helpers

    private static func symbol(_ name: String, size: CGFloat, color: UIColor) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: symbol.size)
        return renderer.image { _ in
            color.setFill()
            symbol.withRenderingMode(.alwaysTemplate).draw(at: .zero)
        }
    }
}
