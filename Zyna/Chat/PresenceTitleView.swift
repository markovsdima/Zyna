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
    }

    private func updateStatus() {
        guard let presence else {
            statusLabel.text = nil
            statusLabel.isHidden = true
            return
        }

        statusLabel.isHidden = false
        if presence.online {
            statusLabel.text = "online"
            statusLabel.textColor = .systemGreen
        } else if let lastSeen = presence.lastSeen {
            statusLabel.text = Self.formatLastSeen(lastSeen)
            statusLabel.textColor = .secondaryLabel
        } else {
            statusLabel.text = nil
            statusLabel.isHidden = true
        }
    }

    private static func formatLastSeen(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:       return "last seen just now"
        case ..<3600:     return "last seen \(Int(diff / 60)) min ago"
        case ..<86400:    return "last seen today"
        default:          return "last seen recently"
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }
}
