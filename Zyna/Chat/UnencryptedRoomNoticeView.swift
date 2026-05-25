//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class UnencryptedRoomNoticeView: UIView {

    private enum Metrics {
        static let height: CGFloat = 26
        static let bottomGap: CGFloat = 8
        static let horizontalMargin: CGFloat = 16
        static let horizontalPadding: CGFloat = 7
        static let iconSize: CGFloat = 14
        static let iconTextGap: CGFloat = 6
        static let minWidth: CGFloat = 112
    }

    var sourceView: UIView? {
        didSet { anchor.sourceView = sourceView }
    }

    var additionalCoveredHeight: CGFloat {
        isHidden ? 0 : Metrics.height + Metrics.bottomGap
    }

    private let anchor = GlassAnchor()
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        anchor.debugName = "unencrypted-notice"
        anchor.cornerRadius = Metrics.height / 2
        anchor.backdropClearColor = AppColor.chatBackground
        anchor.onAdaptiveMaterialChanged = { [weak self] material in
            self?.applyGlassAdaptiveMaterial(material)
        }
        addSubview(anchor)

        iconView.image = AppIcon.lockSlash.template(size: 13, weight: .medium)
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        label.text = String(localized: "Not encrypted")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.86
        addSubview(label)

        accessibilityLabel = label.text
        applyGlassAdaptiveMaterial(anchor.adaptiveMaterial)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateLayout(in parentView: UIView, aboveY: CGFloat) {
        guard !isHidden else {
            frame = .zero
            anchor.frame = .zero
            return
        }

        let maxWidth = max(0, parentView.bounds.width - Metrics.horizontalMargin * 2)
        let labelWidth = ceil(label.intrinsicContentSize.width)
        let measuredWidth = Metrics.horizontalPadding * 2
            + Metrics.iconSize
            + Metrics.iconTextGap
            + labelWidth
        let width = min(max(Metrics.minWidth, measuredWidth), maxWidth)
        let x = floor((parentView.bounds.width - width) / 2)
        let y = floor(aboveY - Metrics.bottomGap - Metrics.height)

        frame = CGRect(x: x, y: y, width: width, height: Metrics.height)
        anchor.frame = bounds
        anchor.renderHostContainerView = parentView
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        anchor.frame = bounds
        let contentWidth = Metrics.iconSize + Metrics.iconTextGap + label.intrinsicContentSize.width
        let startX = max(
            Metrics.horizontalPadding,
            floor((bounds.width - contentWidth) / 2)
        )
        let iconY = floor((bounds.height - Metrics.iconSize) / 2)
        iconView.frame = CGRect(
            x: startX,
            y: iconY,
            width: Metrics.iconSize,
            height: Metrics.iconSize
        )
        label.frame = CGRect(
            x: iconView.frame.maxX + Metrics.iconTextGap,
            y: 0,
            width: max(0, bounds.width - iconView.frame.maxX - Metrics.iconTextGap - Metrics.horizontalPadding),
            height: bounds.height
        )
    }

    private func applyGlassAdaptiveMaterial(_ material: GlassAdaptiveMaterial) {
        iconView.tintColor = material.glyphForeground
        label.textColor = material.primaryForeground
    }
}
