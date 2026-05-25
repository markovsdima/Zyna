//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class ReadOnlyComposerPlaceholderView: UIView {

    private enum Metrics {
        static let contentHeight: CGFloat = 56
        static let horizontalInset: CGFloat = 16
    }

    private let separatorView = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = AppColor.chatBackground

        separatorView.backgroundColor = .separator
        addSubview(separatorView)

        label.text = String(localized: "Notifications toggle will appear here")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        addSubview(label)

        isAccessibilityElement = true
        accessibilityLabel = label.text
    }

    required init?(coder: NSCoder) { fatalError() }

    func coveredHeight(in parentView: UIView) -> CGFloat {
        Metrics.contentHeight + parentView.safeAreaInsets.bottom
    }

    func updateLayout(in parentView: UIView) {
        let height = coveredHeight(in: parentView)
        frame = CGRect(
            x: 0,
            y: parentView.bounds.height - height,
            width: parentView.bounds.width,
            height: height
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        separatorView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        label.frame = CGRect(
            x: Metrics.horizontalInset,
            y: 0,
            width: max(0, bounds.width - Metrics.horizontalInset * 2),
            height: Metrics.contentHeight
        )
    }
}
