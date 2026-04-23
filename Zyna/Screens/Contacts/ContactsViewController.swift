//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine

final class ContactsViewController: ASDKViewController<ASDisplayNode> {

    private let viewModel = ContactsViewModel()
    private let tableNode = ASTableNode()
    private let searchController = UISearchController(searchResultsController: nil)
    private var cancellables = Set<AnyCancellable>()

    var onContactSelected: ((ContactModel) -> Void)? {
        get { viewModel.onContactSelected }
        set { viewModel.onContactSelected = newValue }
    }

    var onCallTapped: ((ContactModel) -> Void)?

    override init() {
        super.init(node: ASDisplayNode())
        title = "Contacts"
        setupTableNode()
        setupSearch()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTableNode() {
        tableNode.delegate = self
        tableNode.dataSource = self
        tableNode.backgroundColor = .systemBackground
        node.backgroundColor = .systemBackground
        node.automaticallyManagesSubnodes = true

        node.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASWrapperLayoutSpec(layoutElement: self.tableNode)
        }
    }

    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search employees")
        definesPresentationContext = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableNode.view.separatorStyle = .none
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func bindViewModel() {
        viewModel.$contacts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableNode.reloadData()
            }
            .store(in: &cancellables)
    }
}

// MARK: - ASTableDataSource & ASTableDelegate

extension ContactsViewController: ASTableDataSource, ASTableDelegate {

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        viewModel.contacts.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let contact = viewModel.contacts[indexPath.row]
        return { [weak self] in
            let cell = ContactsCellNode(model: contact)
            cell.onCallTapped = { [weak self] in
                self?.onCallTapped?(contact)
            }
            return cell
        }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        viewModel.selectContact(at: indexPath.row)
    }
}

// MARK: - UISearchResultsUpdating

extension ContactsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.search(searchController.searchBar.text ?? "")
    }
}
