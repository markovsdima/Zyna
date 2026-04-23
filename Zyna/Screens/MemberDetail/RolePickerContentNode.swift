//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Role list content for `AnchoredPopupNode`. Renders each option as
/// a row: dot in role colour, label, optional checkmark on current.
/// Disabled options are greyed out and don't tap.
final class RolePickerContentNode: ASDisplayNode, AccessibilityFocusProviding {

    struct Option {
        let role: MemberCellNode.Role
        let label: String
        let enabled: Bool
    }

    static let rowHeight: CGFloat = 46

    var onPick: ((MemberCellNode.Role) -> Void)?

    private let options: [Option]
    private let currentRole: MemberCellNode.Role
    private var rowNodes: [TappableNode] = []

    init(options: [Option], currentRole: MemberCellNode.Role) {
        self.options = options
        self.currentRole = currentRole
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .clear
        buildRows()
    }

    private func buildRows() {
        for option in options {
            rowNodes.append(makeRow(for: option))
        }
    }

    private func makeRow(for option: Option) -> TappableNode {
        let node = TappableNode()
        node.automaticallyManagesSubnodes = true
        node.backgroundColor = .clear

        let dotNode = ASDisplayNode()
        dotNode.backgroundColor = option.role.pillColor == .clear ? .systemGray3 : option.role.pillColor
        dotNode.cornerRadius = 5
        dotNode.style.preferredSize = CGSize(width: 10, height: 10)

        let label = ASTextNode()
        label.attributedText = NSAttributedString(
            string: option.label,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: option.enabled ? UIColor.label : UIColor.tertiaryLabel
            ]
        )

        let isCurrent = option.role == currentRole
        let check = ASImageNode()
        if isCurrent {
            check.style.preferredSize = CGSize(width: 14, height: 14)
        }

        node.layoutSpecBlock = { _, _ in
            let leading = ASStackLayoutSpec(
                direction: .horizontal,
                spacing: 10,
                justifyContent: .start,
                alignItems: .center,
                children: [dotNode, label]
            )
            let spacer = ASLayoutSpec()
            spacer.style.flexGrow = 1
            let row = ASStackLayoutSpec.horizontal()
            row.alignItems = .center
            row.children = isCurrent ? [leading, spacer, check] : [leading, spacer]
            return ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14),
                child: row
            )
        }

        // Render checkmark on main (AppIcon force-unwraps UIImage(systemName:)).
        if isCurrent {
            node.onDidLoad { _ in
                check.image = AppIcon.checkmark.rendered(
                    size: 14, weight: .bold, color: AppColor.accent
                )
            }
        }

        if option.enabled {
            let role = option.role
            node.onTap = { [weak self] in self?.onPick?(role) }
        }

        // VO reads "Admin, button" or "Moderator, selected" for the
        // already-applied role. Disabled + selected reads cleaner than
        // ".notEnabled" which would announce the current row as "dimmed".
        node.isAccessibilityElement = true
        node.accessibilityLabel = option.label
        var traits: UIAccessibilityTraits = option.enabled ? .button : []
        if isCurrent { traits.insert(.selected) }
        node.accessibilityTraits = traits
        // VO announces "selected" on the current row; without a hint
        // users try to activate it and get a silent no-op.
        if isCurrent && !option.enabled {
            node.accessibilityHint = String(localized: "Already applied")
        }

        return node
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: rowNodes
        )
    }

    // MARK: - AccessibilityFocusProviding

    var initialAccessibilityFocus: UIView? {
        rowNodes.first(where: { $0.isNodeLoaded })?.view
    }
}

// MARK: - Role helpers

extension MemberCellNode.Role: CaseIterable {
    public static var allCases: [MemberCellNode.Role] {
        [.owner, .admin, .moderator, .member]
    }
}
