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

        node.headerNode.onNextTapped = { [weak self] in
            self?.viewModel.proceed()
        }
        node.headerNode.onSearchQueryChanged = { [weak self] query in
            self?.viewModel.searchUsers(query)
        }

        bindViewModel()
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
                guard let self else { return }
                self.node.chipsStripNode.setUsers(users) { [weak self] user in
                    self?.removeSelected(user: user)
                }
                self.node.showChips = !users.isEmpty
            }
            .store(in: &cancellables)
    }

    private func removeSelected(user: UserProfile) {
        viewModel.removeUser(user)
        guard let row = viewModel.searchResults.firstIndex(where: { $0.userId == user.userId }) else { return }
        let indexPath = IndexPath(row: row, section: 0)
        if let cell = node.tableNode.nodeForRow(at: indexPath) as? UserCellNode {
            cell.isChecked = false
        }
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
        let user = viewModel.searchResults[indexPath.row]
        viewModel.toggleUser(user)
        if let cell = tableNode.nodeForRow(at: indexPath) as? UserCellNode {
            cell.isChecked = viewModel.isSelected(user)
        }
    }
}
