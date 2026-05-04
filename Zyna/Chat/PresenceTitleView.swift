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
                attributes: nameAttributes
            )
            invalidateCalculatedLayout()
            updateAccessibility()
        }
    }

    var presence: UserPresence? {
        didSet { updateStatus() }
    }

    var memberCount: Int? {
        didSet { updateStatus() }
    }

    var isTappable = false {
        didSet { updateAccessibility() }
    }

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
    private var glassMaterial = GlassAdaptiveMaterial.light
    private var lastAppliedGlassAppearance: CGFloat = -1
    private var lastAppliedGlassContrast: CGFloat = -1

    private var nameAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: glassMaterial.primaryForeground,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                return p
            }()
        ]
    }

    private func statusAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
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
        isAccessibilityElement = true
        accessibilityTraits = .header
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

    override func accessibilityActivate() -> Bool {
        guard isTappable else { return false }
        onTapped?()
        return true
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
                setStatus(lastSeen.presenceLastSeenString(style: .chat), color: glassMaterial.secondaryForeground)
            } else {
                hideStatus()
            }
            return
        }

        // Group: show member count
        if let memberCount {
            setStatus(String(localized: "\(memberCount) members"), color: glassMaterial.secondaryForeground)
            return
        }

        hideStatus()
    }

    private func setStatus(_ text: String, color: UIColor) {
        statusHidden = false
        statusNode.attributedText = NSAttributedString(
            string: text,
            attributes: statusAttributes(color: color)
        )
        invalidateCalculatedLayout()
        updateAccessibility()
    }

    private func hideStatus() {
        statusHidden = true
        statusNode.attributedText = nil
        invalidateCalculatedLayout()
        updateAccessibility()
    }

    private func updateAccessibility() {
        var label = name
        if let statusText = statusNode.attributedText?.string, !statusHidden {
            label += ", \(statusText)"
        }
        accessibilityLabel = label
        accessibilityTraits = isTappable ? [.header, .button] : .header
    }
}

extension PresenceTitleNode {
    func applyGlassAdaptiveMaterial(_ material: GlassAdaptiveMaterial) {
        guard abs(material.appearance - lastAppliedGlassAppearance) > 0.012 ||
              abs(material.contrast - lastAppliedGlassContrast) > 0.03 else {
            return
        }

        glassMaterial = material
        lastAppliedGlassAppearance = material.appearance
        lastAppliedGlassContrast = material.contrast

        nameNode.attributedText = NSAttributedString(
            string: name,
            attributes: nameAttributes
        )
        updateStatus()
        invalidateCalculatedLayout()
    }
}
