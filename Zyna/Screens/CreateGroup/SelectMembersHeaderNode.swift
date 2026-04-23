//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SelectMembersHeaderNode: ASDisplayNode {

    var onNextTapped: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    private let backgroundNode = ASDisplayNode()
    private let textField = UITextField()
    private lazy var searchFieldNode: ASDisplayNode = {
        let tf = textField
        return ASDisplayNode(viewBlock: { tf })
    }()
    private let nextButtonNode = ASButtonNode()

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        automaticallyRelayoutOnSafeAreaChanges = true

        backgroundNode.backgroundColor = .systemBackground

        searchFieldNode.style.flexGrow = 1
        searchFieldNode.style.height = ASDimension(unit: .points, value: 36)

        nextButtonNode.setAttributedTitle(
            NSAttributedString(
                string: String(localized: "Next"),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                    .foregroundColor: AppColor.accent
                ]
            ),
            for: .normal
        )
        nextButtonNode.style.flexShrink = 0
        nextButtonNode.addTarget(self, action: #selector(nextTapped), forControlEvents: .touchUpInside)
    }

    override func didLoad() {
        super.didLoad()
        textField.placeholder = String(localized: "Search users")
        textField.backgroundColor = .secondarySystemBackground
        textField.layer.cornerRadius = 10
        textField.leftView = makeSearchIcon()
        textField.leftViewMode = .always
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .search
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.font = .systemFont(ofSize: 16)
        textField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
    }

    @objc private func nextTapped() {
        onNextTapped?()
    }

    @objc private func searchChanged() {
        onSearchQueryChanged?(textField.text ?? "")
    }

    private func makeSearchIcon() -> UIView {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: config))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 36))
        icon.frame = container.bounds
        container.addSubview(icon)
        return container
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 10,
            justifyContent: .start,
            alignItems: .center,
            children: [searchFieldNode, nextButtonNode]
        )

        let padded = ASInsetLayoutSpec(
            insets: UIEdgeInsets(
                top: 6 + safeAreaInsets.top,
                left: 16,
                bottom: 8,
                right: 16
            ),
            child: row
        )

        return ASBackgroundLayoutSpec(child: padded, background: backgroundNode)
    }
}
