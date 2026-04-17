//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class SearchBarView: UIView {

    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onCancel: (() -> Void)?

    private let textField = UITextField()
    private let statusLabel = UILabel()
    private let upButton = UIButton(type: .system)
    private let downButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private let hPad: CGFloat = 16
    private let btnSize: CGFloat = 32
    private let spacing: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = AppColor.searchBarBackground

        textField.placeholder = String(localized: "Search messages")
        textField.font = .systemFont(ofSize: 16)
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.clearButtonMode = .whileEditing
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .right

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        upButton.setImage(UIImage(systemName: "chevron.up", withConfiguration: symbolConfig), for: .normal)
        upButton.addTarget(self, action: #selector(upTapped), for: .touchUpInside)

        downButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: symbolConfig), for: .normal)
        downButton.addTarget(self, action: #selector(downTapped), for: .touchUpInside)

        cancelButton.setImage(UIImage(systemName: "xmark", withConfiguration: symbolConfig), for: .normal)
        cancelButton.tintColor = .secondaryLabel
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        addSubview(textField)
        addSubview(statusLabel)
        addSubview(upButton)
        addSubview(downButton)
        addSubview(cancelButton)

        updateArrows(hasResults: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let cy = h / 2

        // Right to left: cancel, down, up, status
        let cancelX = bounds.width - hPad - btnSize
        cancelButton.frame = CGRect(x: cancelX, y: cy - btnSize / 2, width: btnSize, height: btnSize)

        let downX = cancelX - spacing - btnSize
        downButton.frame = CGRect(x: downX, y: cy - btnSize / 2, width: btnSize, height: btnSize)

        let upX = downX - spacing - btnSize
        upButton.frame = CGRect(x: upX, y: cy - btnSize / 2, width: btnSize, height: btnSize)

        let statusW: CGFloat = 50
        let statusX = upX - spacing - statusW
        statusLabel.frame = CGRect(x: statusX, y: 0, width: statusW, height: h)

        textField.frame = CGRect(x: hPad, y: 0, width: statusX - spacing - hPad, height: h)
    }

    // MARK: - Public

    func activate() {
        textField.text = nil
        statusLabel.text = nil
        updateArrows(hasResults: false)
        textField.becomeFirstResponder()
    }

    func updateStatus(_ text: String, hasResults: Bool) {
        statusLabel.text = text
        updateArrows(hasResults: hasResults)
    }

    // MARK: - Private

    private func updateArrows(hasResults: Bool) {
        upButton.isEnabled = hasResults
        downButton.isEnabled = hasResults
        upButton.alpha = hasResults ? 1 : 0.3
        downButton.alpha = hasResults ? 1 : 0.3
    }

    // MARK: - Actions

    @objc private func textChanged() {
        onQueryChanged?(textField.text ?? "")
    }

    @objc private func upTapped() { onPrevious?() }
    @objc private func downTapped() { onNext?() }

    @objc private func cancelTapped() {
        textField.resignFirstResponder()
        onCancel?()
    }
}
