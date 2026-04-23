//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Full-width filled action button with icon + label.
final class ColoredActionButtonNode: ASDisplayNode {

    enum Style {
        case primary
        case warning
        case destructive

        var backgroundColor: UIColor {
            switch self {
            case .primary:     return AppColor.accent
            case .warning:     return .systemOrange
            case .destructive: return .systemRed
            }
        }
    }

    var onTap: (() -> Void)?

    private let labelNode = ASTextNode()
    private let iconNode = ASImageNode()

    init(title: String, icon: UIImage?, style: Style) {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = style.backgroundColor
        cornerRadius = 12
        clipsToBounds = true

        labelNode.attributedText = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
        )
        labelNode.maximumNumberOfLines = 1

        if let icon {
            iconNode.image = icon.withTintColor(.white, renderingMode: .alwaysOriginal)
            iconNode.style.preferredSize = CGSize(width: 20, height: 20)
        }

        // Whole button as one VO element; otherwise icon + label split.
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    override func didLoad() {
        super.didLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        view.addGestureRecognizer(tap)
    }

    @objc private func tapped() {
        // Flash the press feedback immediately, but defer the action so
        // a navigation transition kicked off by `onTap` doesn't compete
        // with the still-running alpha animation.
        let original = alpha
        alpha = 0.7
        UIView.animate(withDuration: 0.2) { self.alpha = original }
        DispatchQueue.main.async { [weak self] in self?.onTap?() }
    }

    override func accessibilityActivate() -> Bool {
        guard let onTap else { return false }
        onTap()
        return true
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let children: [ASLayoutElement]
        if iconNode.image != nil {
            children = [iconNode, labelNode]
        } else {
            children = [labelNode]
        }
        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 10,
            justifyContent: .center,
            alignItems: .center,
            children: children
        )
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16),
            child: row
        )
    }
}
