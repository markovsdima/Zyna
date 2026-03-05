//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

// MARK: - Chats List Controller
class ChatsListViewController: ASDKViewController<ASDisplayNode> {

    private let viewModel = RoomsViewModel()
    private let tableNode = ASTableNode()
    private var cancellables = Set<AnyCancellable>()

    var onChatSelected: ((Room) -> Void)? {
        get { viewModel.onChatSelected }
        set { viewModel.onChatSelected = newValue }
    }

    override init() {
        super.init(node: BaseNode())

        setupTableNode()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTableNode() {
        tableNode.delegate = self
        tableNode.dataSource = self
        tableNode.backgroundColor = UIColor.systemBackground
        node.addSubnode(tableNode)
        node.backgroundColor = UIColor.systemBackground

        node.layoutSpecBlock = { [weak self] _, constrainedSize in
            guard let self else { return ASLayoutSpec() }
            return ASWrapperLayoutSpec(layoutElement: self.tableNode)
        }
    }

    private func bindViewModel() {
        viewModel.$chats
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableNode.reloadData()
            }
            .store(in: &cancellables)
    }

    @objc private func handleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.tableNode.view.refreshControl?.endRefreshing()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // UIKit view access — safe in viewDidLoad (main thread, view loaded)
        tableNode.view.separatorStyle = .none
        tableNode.view.refreshControl = UIRefreshControl()
        tableNode.view.refreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)

        let composeButton = UIBarButtonItem(
            barButtonSystemItem: .compose,
            target: self,
            action: #selector(composeButtonTapped)
        )
        navigationItem.rightBarButtonItem = composeButton
    }

    @objc private func composeButtonTapped() {
        print("Compose button tapped")
    }
}

// MARK: - Table Node Data Source & Delegate
extension ChatsListViewController: ASTableDataSource, ASTableDelegate {

    func numberOfSections(in tableNode: ASTableNode) -> Int {
        return 1
    }

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        return viewModel.chats.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let chat = viewModel.chats[indexPath.row]
        return {
            return RoomsCellNode(chat: chat)
        }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        viewModel.selectChat(at: indexPath.row)
    }
}

extension ChatsListViewController {
    func tableNode(_ tableNode: ASTableNode, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableNode(_ tableNode: ASTableNode, commitEditingStyle editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            viewModel.deleteChat(at: indexPath.row)
            tableNode.deleteRows(at: [indexPath], with: .fade)
        }
    }
}
