//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Banner shown below the nav bar when the room is in
/// invited state. Shows inviter name and an accept button.
final class InviteBannerView: UIView {

    var onAccept: (() -> Void)?

    private let label = UILabel()
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

        label.frame = CGRect(
            x: hPad,
            y: 0,
            width: acceptButton.frame.minX - hPad * 2,
            height: h
        )
    }

    @objc private func acceptTapped() { onAccept?() }
}
