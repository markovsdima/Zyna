//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

final class SpaceAddExistingChatViewController:
    ASDKViewController<SpaceAddExistingChatNode>,
    ASTableDataSource,
    ASTableDelegate {

    var onBack: (() -> Void)?
    var onChatAdded: ((RoomModel) -> Void)?

    private let viewModel: SpaceAddExistingChatViewModel
    private let headerBar = SpaceAddExistingChatHeaderBar()

    init(viewModel: SpaceAddExistingChatViewModel) {
        self.viewModel = viewModel
        super.init(node: SpaceAddExistingChatNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTable()
        setupHeaderBar()
        bindViewModel()
        viewModel.loadChats()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let topInset = headerBar.frame.height
        if node.tableNode.contentInset.top != topInset {
            node.tableNode.contentInset.top = topInset
            node.tableNode.view.verticalScrollIndicatorInsets.top = topInset
        }
    }

    private func setupTable() {
        node.tableNode.dataSource = self
        node.tableNode.delegate = self
        node.tableNode.view.separatorStyle = .none
        node.tableNode.view.keyboardDismissMode = .onDrag
        node.tableNode.view.contentInsetAdjustmentBehavior = .never
    }

    private func setupHeaderBar() {
        headerBar.configure(title: viewModel.title, subtitle: viewModel.subtitle)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        headerBar.onBackTapped = { [weak self] in
            self?.onBack?()
        }
        headerBar.onSearchQueryChanged = { [weak self] query in
            self?.viewModel.updateSearchQuery(query)
        }

        view.isAccessibilityElement = false
        view.accessibilityElements = [headerBar, node.tableNode.view]
    }

    private func bindViewModel() {
        viewModel.onChanged = { [weak self] in
            self?.node.tableNode.reloadData()
        }
        viewModel.onAddingChanged = { [weak self] isAdding in
            self?.headerBar.updateAdding(isAdding)
            self?.node.tableNode.view.isUserInteractionEnabled = !isAdding
        }
        viewModel.onChatAdded = { [weak self] chat in
            self?.onChatAdded?(chat)
        }
        viewModel.onError = { [weak self] message in
            self?.showError(message)
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Could not add chat"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        max(1, viewModel.chats.count)
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let chats = viewModel.chats
        guard !chats.isEmpty else {
            let message = viewModel.emptyMessage
            return { SpaceEmptyChatsCellNode(message: message) }
        }

        guard chats.indices.contains(indexPath.row) else {
            return { ASCellNode() }
        }
        let chat = chats[indexPath.row]
        return { RoomsCellNode(chat: chat) }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        guard !viewModel.chats.isEmpty else { return }
        viewModel.addChat(at: indexPath.row)
    }
}

private final class SpaceAddExistingChatHeaderBar: UIView {

    var onBackTapped: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let titleStack = UIStackView()
    private let searchField = UITextField()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isAccessibilityElement = false
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        titleStack.accessibilityLabel = [title, subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    func updateAdding(_ isAdding: Bool) {
        backButton.isEnabled = !isAdding
        backButton.alpha = isAdding ? 0.35 : 1
        searchField.isEnabled = !isAdding
        if isAdding {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    private func setupViews() {
        backButton.setImage(
            AppIcon.chevronBackward.template(size: 17, weight: .semibold),
            for: .normal
        )
        backButton.tintColor = .label
        backButton.accessibilityLabel = String(localized: "Back")
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 1

        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)
        titleStack.axis = .vertical
        titleStack.spacing = 1
        titleStack.alignment = .center
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.isAccessibilityElement = true
        titleStack.accessibilityTraits = .header

        searchField.placeholder = String(localized: "Search")
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

        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backButton)
        addSubview(titleStack)
        addSubview(activityIndicator)
        addSubview(searchField)

        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),

            activityIndicator.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            activityIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            titleStack.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: activityIndicator.leadingAnchor, constant: -8),
            titleStack.centerXAnchor.constraint(equalTo: centerXAnchor),

            searchField.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 36),
            searchField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    override var accessibilityElements: [Any]? {
        get { [backButton, titleStack, searchField] }
        set { }
    }

    @objc private func backTapped() {
        onBackTapped?()
    }

    @objc private func searchChanged() {
        onSearchQueryChanged?(searchField.text ?? "")
    }

    private func makeSearchIcon() -> UIView {
        let icon = UIImageView(image: AppIcon.magnifyingGlass.template(size: 14, weight: .medium))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 36))
        icon.frame = container.bounds
        container.addSubview(icon)
        return container
    }
}
