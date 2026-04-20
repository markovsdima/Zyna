//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class MemberCellNode: ZynaCellNode {

    // MARK: - Model

    enum Role {
        case owner      // PL 100
        case admin      // PL 50..99
        case moderator  // PL 1..49
        case member     // PL 0

        /// Localized role name. Always non-nil — used in a11y labels
        /// and the role picker.
        var localizedLabel: String {
            switch self {
            case .owner:     return String(localized: "Owner")
            case .admin:     return String(localized: "Admin")
            case .moderator: return String(localized: "Mod")
            case .member:    return String(localized: "Member")
            }
        }

        /// Pill text rendered next to the member name. Nil for plain
        /// members — the pill is omitted in that case.
        var pillLabel: String? {
            switch self {
            case .member: return nil
            default:      return localizedLabel
            }
        }

        var pillColor: UIColor {
            switch self {
            case .owner:     return AppColor.accent
            case .admin:     return .systemOrange
            case .moderator: return .systemGray
            case .member:    return .clear
            }
        }

        static func from(powerLevel: Int) -> Role {
            switch powerLevel {
            case 100...:  return .owner
            case 50..<100: return .admin
            case 1..<50:   return .moderator
            default:       return .member
            }
        }
    }

    struct Model {
        let userId: String
        let displayName: String?
        let avatarUrl: String?
        var role: Role
        var presence: UserPresence?

        var name: String { displayName ?? userId }
    }

    // MARK: - Subnodes

    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let nameNode = ASTextNode()
    private let statusNode = ASTextNode()
    private let rolePillBackground = RoundedBackgroundNode()
    private let roleNode = ASTextNode()
    private let separatorNode = ASDisplayNode()

    private static let avatarDiameter: CGFloat = 44
    private static let avatarThumbSize: Int = Int(avatarDiameter * ScreenConstants.scale)

    // MARK: - State

    private var model: Model

    init(model: Model) {
        self.model = model
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .default
        backgroundColor = .systemBackground
        setupNodes()
    }

    // MARK: - Setup

    private func setupNodes() {
        let avatar = AvatarViewModel(
            userId: model.userId,
            displayName: model.displayName,
            mxcAvatarURL: model.avatarUrl
        )
        avatarBackgroundNode.image = avatar.circleImage(
            diameter: Self.avatarDiameter, fontSize: 16
        )
        avatarBackgroundNode.isLayerBacked = true
        avatarBackgroundNode.isOpaque = false

        avatarImageNode.isLayerBacked = true
        avatarImageNode.isOpaque = false
        avatarImageNode.contentMode = .scaleAspectFill
        loadAvatar()

        nameNode.attributedText = Self.nameAttributed(model.name)
        nameNode.maximumNumberOfLines = 1
        nameNode.truncationMode = .byTruncatingTail

        statusNode.attributedText = Self.statusAttributed(for: model.presence)
        statusNode.maximumNumberOfLines = 1

        if let label = model.role.pillLabel {
            rolePillBackground.fillColor = model.role.pillColor
            rolePillBackground.radius = 9
            roleNode.attributedText = NSAttributedString(
                string: label,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: UIColor.white
                ]
            )
        }

        separatorNode.backgroundColor = .separator
        // Snap to a single device pixel so it doesn't blur or fatten
        // depending on screen scale (0.5pt is a half-pixel on @2x).
        separatorNode.style.height = ASDimension(unit: .points, value: 1 / ScreenConstants.scale)

        isAccessibilityElement = true
        accessibilityTraits = .button
        refreshAccessibilityLabel()
    }

    private func refreshAccessibilityLabel() {
        var parts: [String] = [model.name]
        if let role = model.role.pillLabel { parts.append(role) }
        parts.append(Self.statusPlainText(for: model.presence))
        accessibilityLabel = parts.joined(separator: ", ")
    }

    private func loadAvatar() {
        guard let mxc = model.avatarUrl else { return }
        let diameter = Self.avatarDiameter
        if let source = MediaCache.shared.cachedImage(for: mxc) {
            avatarImageNode.image = CircularImageCache.roundedImage(
                source: source, diameter: diameter, cacheKey: mxc
            )
            return
        }
        Task { [weak self] in
            guard let source = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: Self.avatarThumbSize) else { return }
            let rounded = CircularImageCache.roundedImage(
                source: source, diameter: diameter, cacheKey: mxc
            )
            self?.avatarImageNode.image = rounded
        }
    }

    // MARK: - In-place update

    /// Refresh the status line without rebuilding the cell.
    /// Driven by presence ticks from the list viewmodel.
    func updatePresence(_ presence: UserPresence?) {
        model.presence = presence
        statusNode.attributedText = Self.statusAttributed(for: presence)
        refreshAccessibilityLabel()
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let avatar = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)
        avatar.style.preferredSize = CGSize(
            width: Self.avatarDiameter, height: Self.avatarDiameter
        )

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .center,
            alignItems: .start,
            children: [nameNode, statusNode]
        )
        textStack.style.flexShrink = 1
        textStack.style.flexGrow = 1

        var rowChildren: [ASLayoutElement] = [avatar, textStack]
        if model.role.pillLabel != nil {
            let pill = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8),
                child: roleNode
            )
            let pillWithBg = ASBackgroundLayoutSpec(child: pill, background: rolePillBackground)
            rowChildren.append(pillWithBg)
        }

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: rowChildren
        )
        let rowInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16),
            child: row
        )

        let separatorInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 16 + Self.avatarDiameter + 12, bottom: 0, right: 0),
            child: separatorNode
        )

        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [rowInset, separatorInset]
        )
    }

    // MARK: - Text

    private static func nameAttributed(_ name: String) -> NSAttributedString {
        NSAttributedString(
            string: name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: UIColor.label
            ]
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func statusAttributed(for presence: UserPresence?) -> NSAttributedString {
        let color: UIColor = presence?.online == true ? AppColor.accent : .secondaryLabel
        return NSAttributedString(
            string: statusPlainText(for: presence),
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: color
            ]
        )
    }

    private static func statusPlainText(for presence: UserPresence?) -> String {
        if let presence, presence.online {
            return String(localized: "Online")
        }
        if let presence, let lastSeen = presence.lastSeen {
            let ago = relativeFormatter.localizedString(for: lastSeen, relativeTo: Date())
            return String(localized: "Last seen \(ago)")
        }
        return String(localized: "Offline")
    }
}
