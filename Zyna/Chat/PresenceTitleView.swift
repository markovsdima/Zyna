//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class PresenceTitleNode: ASDisplayNode {

    var name: String = "" {
        didSet {
            nameNode.attributedText = NSAttributedString(
                string: name,
                attributes: Self.nameAttributes
            )
            invalidateCalculatedLayout()
        }
    }

    var presence: UserPresence? {
        didSet { updateStatus() }
    }

    var memberCount: Int? {
        didSet { updateStatus() }
    }

    var isTappable = false

    var onTapped: (() -> Void)?

    /// Intrinsic width of the name/status stack (for glass shape sizing).
    var contentWidth: CGFloat {
        let nameSize = nameNode.attributedText?.size() ?? .zero
        let statusSize = statusNode.attributedText?.size() ?? .zero
        return ceil(max(nameSize.width, statusSize.width))
    }

    private let nameNode = ASTextNode()
    private let statusNode = ASTextNode()
    private var statusHidden = true

    private static let nameAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: UIColor.label,
        .paragraphStyle: {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            return p
        }()
    ]

    private static func statusAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                return p
            }()
        ]
    }

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        nameNode.maximumNumberOfLines = 1
        statusNode.maximumNumberOfLines = 1
    }

    override func didLoad() {
        super.didLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        guard isTappable else { return }
        onTapped?()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        var children: [ASLayoutElement] = [nameNode]
        if !statusHidden {
            children.append(statusNode)
        }
        let stack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 1,
            justifyContent: .center,
            alignItems: .center,
            children: children
        )
        return ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: .minimumXY, child: stack)
    }

    private func updateStatus() {
        // DM: show presence
        if let presence {
            if presence.online {
                setStatus(String(localized: "online"), color: .systemGreen)
            } else if let lastSeen = presence.lastSeen {
                setStatus(lastSeen.presenceLastSeenString(style: .chat), color: .secondaryLabel)
            } else {
                hideStatus()
            }
            return
        }

        // Group: show member count
        if let memberCount {
            setStatus(String(localized: "\(memberCount) members"), color: .secondaryLabel)
            return
        }

        hideStatus()
    }

    private func setStatus(_ text: String, color: UIColor) {
        statusHidden = false
        statusNode.attributedText = NSAttributedString(
            string: text,
            attributes: Self.statusAttributes(color: color)
        )
        invalidateCalculatedLayout()
    }

    private func hideStatus() {
        statusHidden = true
        statusNode.attributedText = nil
        invalidateCalculatedLayout()
    }
}
