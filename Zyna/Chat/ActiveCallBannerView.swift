//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class ActiveCallBannerView: UIControl {

    static let height: CGFloat = 48

    var onJoin: (() -> Void)?

    private let iconBackgroundView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let joinButton = UIButton(type: .system)
    private let horizontalPadding: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        accessibilityLabel = String(localized: "Call in progress")
        accessibilityHint = String(localized: "Join Call")
        addTarget(self, action: #selector(joinTapped), for: .touchUpInside)

        iconBackgroundView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.16)
        iconBackgroundView.layer.cornerRadius = 15
        iconBackgroundView.clipsToBounds = true
        iconBackgroundView.isUserInteractionEnabled = false

        iconView.image = AppIcon.phone.template(size: 14, weight: .semibold)
        iconView.tintColor = .systemGreen
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false

        titleLabel.text = String(localized: "Call in progress")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false

        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Join")
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = .systemGreen
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 7,
            leading: 14,
            bottom: 7,
            trailing: 14
        )
        joinButton.configuration = configuration
        joinButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        joinButton.accessibilityLabel = String(localized: "Join Call")
        joinButton.addTarget(self, action: #selector(joinTapped), for: .touchUpInside)
        joinButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconBackgroundView)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(joinButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let h = bounds.height
        let iconSize: CGFloat = 30
        let iconFrame = CGRect(
            x: horizontalPadding,
            y: (h - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        iconBackgroundView.frame = iconFrame
        iconView.frame = iconFrame

        let buttonSize = joinButton.sizeThatFits(
            CGSize(width: bounds.width / 2, height: h)
        )
        let buttonWidth = min(max(buttonSize.width, 64), max(64, bounds.width * 0.34))
        joinButton.frame = CGRect(
            x: bounds.width - horizontalPadding - buttonWidth,
            y: (h - 34) / 2,
            width: buttonWidth,
            height: 34
        )

        let labelX = iconFrame.maxX + 10
        titleLabel.frame = CGRect(
            x: labelX,
            y: 0,
            width: max(0, joinButton.frame.minX - labelX - 12),
            height: h
        )
    }

    @objc private func joinTapped() {
        onJoin?()
    }
}
