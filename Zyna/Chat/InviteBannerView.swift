//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Banner shown below the nav bar when the room is in
/// invited state. Offers acceptance and the decline/block form.
final class InviteBannerView: UIView {

    var onDecline: (() -> Void)?
    var onAccept: (() -> Void)?

    private let label = UILabel()
    private let declineButton = UIButton(type: .system)
    private let acceptButton = UIButton(type: .system)
    private let hPad: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = AppColor.inviteBannerBackground

        label.text = String(localized: "You've been invited to this chat")
        label.font = .systemFont(ofSize: 14)
        label.textColor = .label
        label.numberOfLines = 1

        acceptButton.setTitle(String(localized: "Accept"), for: .normal)
        acceptButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        acceptButton.addTarget(self, action: #selector(acceptTapped), for: .touchUpInside)

        declineButton.setTitle(String(localized: "Decline", table: "Reports"), for: .normal)
        declineButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        declineButton.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)
        addSubview(declineButton)
        addSubview(label)
        addSubview(acceptButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height

        let btnW = acceptButton.intrinsicContentSize.width + 16
        acceptButton.frame = CGRect(
            x: bounds.width - hPad - btnW,
            y: 0,
            width: btnW,
            height: h
        )

        let declineWidth = declineButton.intrinsicContentSize.width + 16
        declineButton.frame = CGRect(x: acceptButton.frame.minX - declineWidth, y: 0, width: declineWidth, height: h)
        label.frame = CGRect(
            x: hPad,
            y: 0,
            width: max(0, declineButton.frame.minX - hPad * 2),
            height: h
        )
    }

    @objc private func declineTapped() { onDecline?() }
    @objc private func acceptTapped() { onAccept?() }
}
