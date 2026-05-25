//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class PinnedMessagesBannerView: UIControl {

    static let height: CGFloat = 36
    static let collapsedSize = CGSize(width: 36, height: 36)

    enum DisplayMode: Equatable {
        case collapsed
        case expanded
    }

    private let indicatorLabel = UILabel()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()

    private var displayMode: DisplayMode = .collapsed
    private var pinnedCount = 0

    private static var accentTint: UIColor {
        ChatBubbleThemeStore.shared.selectedTheme.actionAccentColor
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.62)
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous
        clipsToBounds = true

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Pinned Messages")
        accessibilityHint = String(localized: "Opens a pinned message")

        indicatorLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        indicatorLabel.textColor = Self.accentTint
        indicatorLabel.textAlignment = .center
        indicatorLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        iconView.image = AppIcon.pin.rendered(size: 14, weight: .semibold, color: Self.accentTint)
        iconView.contentMode = .center

        titleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.text = String(localized: "Pinned Messages")
        titleLabel.numberOfLines = 1

        previewLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 1

        addSubview(indicatorLabel)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(previewLabel)
    }

    func configure(index: Int, count: Int, preview: String?, mode: DisplayMode) {
        displayMode = mode
        pinnedCount = count
        layer.cornerRadius = mode == .collapsed ? Self.collapsedSize.height / 2 : bounds.height / 2

        guard count > 0 else {
            indicatorLabel.text = nil
            previewLabel.text = nil
            accessibilityValue = nil
            updateModeVisibility()
            return
        }

        switch mode {
        case .collapsed:
            indicatorLabel.text = count > 1 ? "\(count)" : nil
        case .expanded:
            indicatorLabel.text = count > 1 ? "\(index + 1)/\(count)" : nil
        }
        previewLabel.text = preview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "Pinned message")
        accessibilityValue = count > 1
            ? "\(index + 1) of \(count). \(previewLabel.text ?? "")"
            : previewLabel.text
        accessibilityHint = mode == .collapsed
            ? String(localized: "Expands pinned messages")
            : String(localized: "Opens a pinned message")
        updateModeVisibility()
        setNeedsLayout()
    }

    private func updateModeVisibility() {
        let isCollapsed = displayMode == .collapsed
        titleLabel.alpha = isCollapsed ? 0 : 1
        previewLabel.alpha = isCollapsed ? 0 : 1
        indicatorLabel.alpha = pinnedCount > 1 ? 1 : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.height / 2

        if displayMode == .collapsed {
            layoutCollapsed()
            return
        }

        layoutExpanded()
    }

    private func layoutCollapsed() {
        let iconSide: CGFloat = 15
        iconView.frame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: (bounds.height - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )

        if let text = indicatorLabel.text, !text.isEmpty {
            let size = indicatorLabel.sizeThatFits(CGSize(width: 24, height: 12))
            indicatorLabel.frame = CGRect(
                x: bounds.maxX - max(12, size.width) - 6,
                y: bounds.minY + 5,
                width: max(12, size.width),
                height: 12
            )
        } else {
            indicatorLabel.frame = .zero
        }

        titleLabel.frame = .zero
        previewLabel.frame = .zero
    }

    private func layoutExpanded() {
        let bounds = bounds.insetBy(dx: 10, dy: 4)
        var x = bounds.minX
        let midY = bounds.midY

        if let text = indicatorLabel.text, !text.isEmpty {
            let size = indicatorLabel.sizeThatFits(
                CGSize(width: 56, height: bounds.height)
            )
            let width = min(max(size.width, 24), 56)
            indicatorLabel.frame = CGRect(
                x: x,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
            x = indicatorLabel.frame.maxX + 8
        } else {
            indicatorLabel.frame = .zero
        }

        iconView.frame = CGRect(x: x, y: midY - 7.5, width: 15, height: 15)
        x = iconView.frame.maxX + 7

        let textWidth = max(0, bounds.maxX - x)
        titleLabel.frame = CGRect(x: x, y: bounds.minY, width: textWidth, height: 14)
        previewLabel.frame = CGRect(x: x, y: titleLabel.frame.maxY, width: textWidth, height: 14)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
