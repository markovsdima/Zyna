//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class PresenceTitleView: UIView {

    var name: String = "" {
        didSet { nameLabel.text = name }
    }

    var presence: UserPresence? {
        didSet { updateStatus() }
    }

    var memberCount: Int? {
        didSet { updateStatus() }
    }

    var isTappable = false {
        didSet { tapRecognizer.isEnabled = isTappable }
    }

    var contentWidth: CGFloat {
        stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
    }

    var onTapped: (() -> Void)?

    private lazy var tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))

    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textAlignment = .center

        statusLabel.font = .systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 1
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(statusLabel)

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])

        tapRecognizer.isEnabled = false
        addGestureRecognizer(tapRecognizer)
    }

    @objc private func handleTap() {
        onTapped?()
    }

    private func updateStatus() {
        // DM: show presence
        if let presence {
            statusLabel.isHidden = false
            if presence.online {
                statusLabel.text = String(localized: "online")
                statusLabel.textColor = .systemGreen
            } else if let lastSeen = presence.lastSeen {
                statusLabel.text = lastSeen.presenceLastSeenString(style: .chat)
                statusLabel.textColor = .secondaryLabel
            } else {
                statusLabel.text = nil
                statusLabel.isHidden = true
            }
            return
        }

        // Group: show member count
        if let memberCount {
            statusLabel.isHidden = false
            // TODO: Replace with stringsdict plural rules when adding localization
            statusLabel.text = "\(memberCount) member\(memberCount == 1 ? "" : "s")"
            statusLabel.textColor = .secondaryLabel
            return
        }

        statusLabel.text = nil
        statusLabel.isHidden = true
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }
}
