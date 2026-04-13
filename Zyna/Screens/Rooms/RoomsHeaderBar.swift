//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class RoomsHeaderBar: UIView {

    var onComposeTapped: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    var connectionStatus: String? {
        didSet {
            searchField.placeholder = connectionStatus ?? "Search"
        }
    }

    private let composeButton = UIButton(type: .system)
    private let searchField = UITextField()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        // Compose button
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        composeButton.setImage(
            UIImage(systemName: "square.and.pencil", withConfiguration: config),
            for: .normal
        )
        composeButton.addTarget(self, action: #selector(composeTapped), for: .touchUpInside)
        composeButton.translatesAutoresizingMaskIntoConstraints = false

        // Search field
        searchField.placeholder = "Search"
        searchField.backgroundColor = .secondarySystemBackground
        searchField.layer.cornerRadius = 10
        searchField.leftView = makeSearchIcon()
        searchField.leftViewMode = .always
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.font = .systemFont(ofSize: 16)
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(composeButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: composeButton.leadingAnchor, constant: -10),
            searchField.heightAnchor.constraint(equalToConstant: 36),
            searchField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            composeButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            composeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composeButton.widthAnchor.constraint(equalToConstant: 36),
            composeButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func composeTapped() {
        onComposeTapped?()
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
