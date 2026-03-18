//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class SelectMembersViewController: ASDKViewController<SelectMembersNode>, ASTableDataSource, ASTableDelegate {

    private let viewModel: SelectMembersViewModel
    private var cancellables = Set<AnyCancellable>()
    private let searchController = UISearchController(searchResultsController: nil)
    private var nextButton: UIBarButtonItem!

    // Chips scroll view for selected users
    private let chipsScrollView = UIScrollView()
    private let chipsStack = UIStackView()

    init(viewModel: SelectMembersViewModel) {
        self.viewModel = viewModel
        super.init(node: SelectMembersNode())
        title = "Add Members"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        node.tableNode.dataSource = self
        node.tableNode.delegate = self
        node.tableNode.view.separatorStyle = .none
        node.tableNode.view.keyboardDismissMode = .onDrag

        setupNavigation()
        setupSearch()
        setupChipsView()
        bindViewModel()
    }

    // MARK: - Setup

    private func setupNavigation() {
        nextButton = UIBarButtonItem(title: "Next", style: .done, target: self, action: #selector(nextTapped))
        navigationItem.rightBarButtonItem = nextButton
    }

    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search users"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func setupChipsView() {
        chipsScrollView.showsHorizontalScrollIndicator = false
        chipsScrollView.alwaysBounceHorizontal = true

        chipsStack.axis = .horizontal
        chipsStack.spacing = 8
        chipsStack.alignment = .center

        chipsScrollView.addSubview(chipsStack)
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chipsStack.leadingAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            chipsStack.trailingAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            chipsStack.topAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.topAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.bottomAnchor),
            chipsStack.heightAnchor.constraint(equalTo: chipsScrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private func bindViewModel() {
        viewModel.$searchResults
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.node.tableNode.reloadData()
            }
            .store(in: &cancellables)

        viewModel.$selectedUsers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] users in
                self?.updateChips(users)
                self?.node.tableNode.reloadData()
            }
            .store(in: &cancellables)
    }

    // MARK: - Chips

    private func updateChips(_ users: [UserProfile]) {
        chipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for user in users {
            let chipNode = SelectedUserChipNode(user: user)
            chipNode.onRemove = { [weak self] in
                self?.viewModel.removeUser(user)
            }
            let chipView = chipNode.view
            chipView.translatesAutoresizingMaskIntoConstraints = false
            chipsStack.addArrangedSubview(chipView)
        }

        let hasChips = !users.isEmpty
        let targetHeight: CGFloat = hasChips ? 44 : 0
        if chipsScrollView.superview == nil && hasChips {
            node.view.addSubview(chipsScrollView)
            chipsScrollView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                chipsScrollView.topAnchor.constraint(equalTo: node.view.safeAreaLayoutGuide.topAnchor),
                chipsScrollView.leadingAnchor.constraint(equalTo: node.view.leadingAnchor),
                chipsScrollView.trailingAnchor.constraint(equalTo: node.view.trailingAnchor),
                chipsScrollView.heightAnchor.constraint(equalToConstant: targetHeight)
            ])
            node.tableNode.contentInset.top = targetHeight
        } else if !hasChips {
            chipsScrollView.removeFromSuperview()
            node.tableNode.contentInset.top = 0
        }
    }

    // MARK: - Actions

    @objc private func nextTapped() {
        viewModel.proceed()
    }

    // MARK: - ASTableDataSource

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        viewModel.searchResults.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let results = viewModel.searchResults
        guard indexPath.row < results.count else { return { ASCellNode() } }
        let user = results[indexPath.row]
        let isSelected = viewModel.isSelected(user)
        return {
            UserCellNode(user: user, isSelected: isSelected, showCheckmark: true)
        }
    }

    // MARK: - ASTableDelegate

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < viewModel.searchResults.count else { return }
        viewModel.toggleUser(viewModel.searchResults[indexPath.row])
    }
}

// MARK: - UISearchResultsUpdating

extension SelectMembersViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.searchUsers(searchController.searchBar.text ?? "")
    }
}
