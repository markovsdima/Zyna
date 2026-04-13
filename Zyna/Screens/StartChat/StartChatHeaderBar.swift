//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class StartChatHeaderBar: UIView {

    var onCancelTapped: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    private let cancelButton = UIButton(type: .system)
    private let searchField = UITextField()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        // Cancel button
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        // Search field
        searchField.placeholder = "Search users (@user:server)"
        searchField.backgroundColor = .secondarySystemBackground
        searchField.layer.cornerRadius = 10
        searchField.leftView = makeSearchIcon()
        searchField.leftViewMode = .always
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.font = .systemFont(ofSize: 16)
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
            searchField.heightAnchor.constraint(equalToConstant: 36),
            searchField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            cancelButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            searchField.becomeFirstResponder()
        }
    }

    @objc private func cancelTapped() {
        onCancelTapped?()
    }

    @objc private func searchChanged() {
        onSearchQueryChanged?(searchField.text ?? "")
    }

    private func makeSearchIcon() -> UIView {
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: config))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 36))
        icon.frame = container.bounds
        container.addSubview(icon)
        return container
    }
}
