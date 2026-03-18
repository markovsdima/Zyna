//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class StartChatViewController: ASDKViewController<StartChatNode>, ASTableDataSource, ASTableDelegate {

    private let viewModel: StartChatViewModel
    private var cancellables = Set<AnyCancellable>()
    private let searchController = UISearchController(searchResultsController: nil)

    init(viewModel: StartChatViewModel) {
        self.viewModel = viewModel
        super.init(node: StartChatNode())
        title = "New Chat"
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
        bindViewModel()
    }

    // MARK: - Setup

    private func setupNavigation() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
    }

    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search users (@user:server)"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func bindViewModel() {
        viewModel.$users
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.node.tableNode.reloadData()
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    // MARK: - ASTableDataSource

    func numberOfSections(in tableNode: ASTableNode) -> Int { 2 }

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : viewModel.users.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        if indexPath.section == 0 {
            return {
                let cell = ASCellNode()
                cell.automaticallyManagesSubnodes = true

                let icon = ASImageNode()
                icon.image = UIImage(systemName: "person.2.fill")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
                icon.style.preferredSize = CGSize(width: 24, height: 24)

                let text = ASTextNode()
                text.attributedText = NSAttributedString(
                    string: "New Group",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                        .foregroundColor: UIColor.systemBlue
                    ]
                )

                let separator = ASDisplayNode()
                separator.backgroundColor = .separator
                separator.style.height = ASDimension(unit: .points, value: 0.5)

                cell.layoutSpecBlock = { _, _ in
                    let row = ASStackLayoutSpec(
                        direction: .horizontal,
                        spacing: 12,
                        justifyContent: .start,
                        alignItems: .center,
                        children: [icon, text]
                    )
                    let padded = ASInsetLayoutSpec(
                        insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16),
                        child: row
                    )
                    let stack = ASStackLayoutSpec.vertical()
                    stack.children = [padded, separator]
                    return stack
                }
                return cell
            }
        }

        let users = viewModel.users
        guard indexPath.row < users.count else { return { ASCellNode() } }
        let user = users[indexPath.row]
        return {
            UserCellNode(user: user)
        }
    }

    // MARK: - ASTableDelegate

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            viewModel.newGroupTapped()
        } else {
            guard indexPath.row < viewModel.users.count else { return }
            viewModel.selectUser(viewModel.users[indexPath.row])
        }
    }
}

// MARK: - UISearchResultsUpdating

extension StartChatViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.searchUsers(searchController.searchBar.text ?? "")
    }
}
