//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class ReadOnlyComposerPlaceholderView: UIView {
    var onUnblock: (() -> Void)?
    private let separatorView = UIView()
    private let label = UILabel()
    private let detailLabel = UILabel()
    private let unblockButton = UIButton(type: .system)
    private var blockedName: String?
    private var unblocking = false
    private var measuredWidth: CGFloat = -1
    private var contentHeight: CGFloat = 56
    private var titleHeight: CGFloat = 0
    private var detailHeight: CGFloat = 0
    private var buttonHeight: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppColor.chatBackground
        separatorView.backgroundColor = .separator
        addSubview(separatorView)
        for text in [label, detailLabel] {
            text.textAlignment = .center
            text.numberOfLines = 0
            text.adjustsFontForContentSizeCategory = true
            addSubview(text)
        }
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 2
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.text = String(localized: "Their messages are hidden in all chats.", table: "Blocking")
        unblockButton.addTarget(self, action: #selector(unblockTapped), for: .touchUpInside)
        unblockButton.accessibilityIdentifier = "chat.unblock"
        unblockButton.titleLabel?.adjustsFontForContentSizeCategory = true
        addSubview(unblockButton)
        applyContent()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ReadOnlyComposerPlaceholderView, _) in
            view.measuredWidth = -1
            view.setNeedsLayout()
            view.superview?.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(blockedName: String?, isUnblocking: Bool) {
        guard self.blockedName != blockedName || unblocking != isUnblocking else { return }
        self.blockedName = blockedName; unblocking = isUnblocking
        applyContent()
    }

    private func applyContent() {
        label.text = blockedName.map { String(localized: "You blocked \($0)", table: "Blocking") }
            ?? String(localized: "Notifications toggle will appear here")
        label.textColor = blockedName == nil ? .secondaryLabel : .label
        detailLabel.isHidden = blockedName == nil
        unblockButton.isHidden = blockedName == nil
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Unblock")
        configuration.baseBackgroundColor = AppColor.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.showsActivityIndicator = unblocking
        configuration.contentInsets = .init(top: 10, leading: 20, bottom: 10, trailing: 20)
        unblockButton.configuration = configuration
        unblockButton.isEnabled = !unblocking
        isAccessibilityElement = blockedName == nil
        accessibilityLabel = blockedName == nil ? label.text : nil
        accessibilityIdentifier = "chat.composerPlaceholder"
        measuredWidth = -1
        setNeedsLayout()
    }

    func coveredHeight(in parentView: UIView) -> CGFloat {
        measure(width: parentView.bounds.width)
        return contentHeight + parentView.safeAreaInsets.bottom
    }

    func updateLayout(in parentView: UIView) {
        let height = coveredHeight(in: parentView)
        frame = CGRect(x: 0, y: parentView.bounds.height - height, width: parentView.bounds.width, height: height)
    }

    private func measure(width: CGFloat) {
        guard measuredWidth != width else { return }
        measuredWidth = width
        let available = CGSize(width: max(0, width - 32), height: .greatestFiniteMagnitude)
        titleHeight = ceil(label.sizeThatFits(available).height)
        if blockedName == nil { contentHeight = max(56, titleHeight + 24); return }
        detailHeight = ceil(detailLabel.sizeThatFits(available).height)
        buttonHeight = max(44, ceil(unblockButton.sizeThatFits(
            CGSize(width: max(0, width - 48), height: .greatestFiniteMagnitude)).height))
        contentHeight = 16 + titleHeight + 6 + detailHeight + 12 + buttonHeight + 12
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        measure(width: bounds.width)
        separatorView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        label.frame = CGRect(x: 16, y: blockedName == nil ? (contentHeight - titleHeight) / 2 : 16,
                             width: max(0, bounds.width - 32), height: titleHeight)
        detailLabel.frame = CGRect(x: 16, y: label.frame.maxY + 6,
                                   width: max(0, bounds.width - 32), height: detailHeight)
        unblockButton.frame = CGRect(x: 24, y: detailLabel.frame.maxY + 12,
                                     width: max(0, bounds.width - 48), height: buttonHeight)
    }

    @objc private func unblockTapped() { onUnblock?() }
}
