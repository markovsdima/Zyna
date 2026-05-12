//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine

final class ContactsScreenNode: ASDisplayNode {
    weak var tableNode: ASTableNode?
    weak var voicePlayerView: UIView?

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let player = voicePlayerView,
               player.superview === view,
               !player.isHidden,
               player.alpha > 0.01 {
                elements.append(player)
            }
            if let tableView = tableNode?.view, tableView.superview === view {
                elements.append(tableView)
            }
            return elements
        }
        set { }
    }
}

final class ContactsViewController: ASDKViewController<ContactsScreenNode> {

    private let viewModel = ContactsViewModel()
    private let tableNode = ASTableNode()
    private let searchController = UISearchController(searchResultsController: nil)
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?
    private var cancellables = Set<AnyCancellable>()

    var onContactSelected: ((ContactModel) -> Void)? {
        get { viewModel.onContactSelected }
        set { viewModel.onContactSelected = newValue }
    }

    var onCallTapped: ((ContactModel) -> Void)?

    init(audioPlayer: AudioPlayerService? = nil) {
        super.init(node: ContactsScreenNode())
        self.voicePlayerHost = audioPlayer.map {
            EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: $0)
        }
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
        node.tableNode = tableNode

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
        setupVoicePlayerHost()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voicePlayerHost?.refresh()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        voicePlayerHost?.layout()
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

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
        node.voicePlayerView = voicePlayerHost?.accessibilityView
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
