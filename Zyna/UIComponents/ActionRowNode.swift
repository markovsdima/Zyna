//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ActionRowNode: ASDisplayNode {

    enum Accessory: Equatable {
        case none
        case chevronForward
        case chevronDown
    }

    struct Configuration {
        var title: String
        var leadingIcon: UIImage?
        var trailingText: String?
        var accessory: Accessory
        var isEnabled: Bool
        var titleColor: UIColor?
        var accessibilityLabel: String?
        var accessibilityHint: String?

        init(
            title: String,
            leadingIcon: UIImage? = nil,
            trailingText: String? = nil,
            accessory: Accessory = .chevronForward,
            isEnabled: Bool = true,
            titleColor: UIColor? = nil,
            accessibilityLabel: String? = nil,
            accessibilityHint: String? = nil
        ) {
            self.title = title
            self.leadingIcon = leadingIcon
            self.trailingText = trailingText
            self.accessory = accessory
            self.isEnabled = isEnabled
            self.titleColor = titleColor
            self.accessibilityLabel = accessibilityLabel
            self.accessibilityHint = accessibilityHint
        }
    }

    var onTap: (() -> Void)?

    private enum Metrics {
        static let radius: CGFloat = 12
        static let insets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        static let spacing: CGFloat = 10
        static let leadingIconSize = CGSize(width: 18, height: 18)
        static let accessorySize = CGSize(width: 12, height: 12)
    }

    private let backgroundNode = RoundedBackgroundNode()
    private let tapNode = TappableNode()
    private let leadingIconNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let trailingTextNode = ASTextNode()
    private let accessoryNode = ASImageNode()

    private var configuration = Configuration(title: "")

    var accessibilityElementView: UIView? {
        guard isNodeLoaded, tapNode.isNodeLoaded else { return nil }
        return tapNode.view
    }

    override init() {
        super.init()
        automaticallyManagesSubnodes = true

        isAccessibilityElement = false
        backgroundNode.fillColor = .secondarySystemBackground
        backgroundNode.radius = Metrics.radius
        backgroundNode.isAccessibilityElement = false
        backgroundNode.accessibilityElementsHidden = true

        tapNode.backgroundColor = .clear
        tapNode.onTap = { [weak self] in
            guard let self, self.configuration.isEnabled else { return }
            self.onTap?()
        }

        leadingIconNode.isAccessibilityElement = false
        leadingIconNode.accessibilityElementsHidden = true
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail
        titleNode.style.flexShrink = 1
        titleNode.isAccessibilityElement = false
        titleNode.accessibilityElementsHidden = true

        trailingTextNode.maximumNumberOfLines = 1
        trailingTextNode.truncationMode = .byTruncatingTail
        trailingTextNode.isAccessibilityElement = false
        trailingTextNode.accessibilityElementsHidden = true

        leadingIconNode.contentMode = .center
        leadingIconNode.style.preferredSize = Metrics.leadingIconSize
        accessoryNode.contentMode = .center
        accessoryNode.style.preferredSize = Metrics.accessorySize
        accessoryNode.isAccessibilityElement = false
        accessoryNode.accessibilityElementsHidden = true
    }

    func apply(_ configuration: Configuration) {
        self.configuration = configuration

        titleNode.attributedText = NSAttributedString(
            string: configuration.title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: configuration.isEnabled
                    ? (configuration.titleColor ?? UIColor.label)
                    : UIColor.secondaryLabel
            ]
        )

        if let trailingText = configuration.trailingText?.nilIfEmpty {
            trailingTextNode.attributedText = NSAttributedString(
                string: trailingText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        } else {
            trailingTextNode.attributedText = nil
        }

        leadingIconNode.image = configuration.leadingIcon
        accessoryNode.image = accessoryImage(for: configuration.accessory)

        let alpha: CGFloat = configuration.isEnabled ? 1 : 0.45
        leadingIconNode.alpha = alpha
        titleNode.alpha = alpha
        trailingTextNode.alpha = alpha
        accessoryNode.alpha = alpha

        tapNode.isAccessibilityElement = true
        tapNode.accessibilityElementsHidden = false
        tapNode.accessibilityTraits = configuration.isEnabled ? .button : .staticText
        tapNode.accessibilityLabel = configuration.accessibilityLabel ?? configuration.title
        tapNode.accessibilityValue = configuration.trailingText
        tapNode.accessibilityHint = configuration.isEnabled ? configuration.accessibilityHint : nil

        setNeedsLayout()
    }

    func updateTrailingText(_ text: String?) {
        var next = configuration
        next.trailingText = text
        apply(next)
    }

    override var accessibilityElements: [Any]? {
        get {
            guard let accessibilityElementView else { return [] }
            return [accessibilityElementView]
        }
        set { }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        var children: [ASLayoutElement] = []
        if configuration.leadingIcon != nil {
            children.append(leadingIconNode)
        }
        children.append(titleNode)

        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1
        children.append(spacer)

        if configuration.trailingText?.nilIfEmpty != nil {
            children.append(trailingTextNode)
        }
        if configuration.accessory != .none {
            children.append(accessoryNode)
        }

        let content = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: Metrics.spacing,
            justifyContent: .start,
            alignItems: .center,
            children: children
        )
        let padded = ASInsetLayoutSpec(insets: Metrics.insets, child: content)
        let withBackground = ASBackgroundLayoutSpec(child: padded, background: backgroundNode)
        let row = ASOverlayLayoutSpec(child: withBackground, overlay: tapNode)
        row.style.alignSelf = .stretch
        return row
    }

    private func accessoryImage(for accessory: Accessory) -> UIImage? {
        switch accessory {
        case .none:
            return nil
        case .chevronForward:
            return AppIcon.chevronForward.rendered(
                size: 12,
                weight: .semibold,
                color: .tertiaryLabel
            )
        case .chevronDown:
            return AppIcon.chevronDown.rendered(
                size: 12,
                weight: .semibold,
                color: .secondaryLabel
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
