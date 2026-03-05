//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine

final class ChatViewController: ASDKViewController<ChatNode>, ASTableDataSource, ASTableDelegate {

    var onBack: (() -> Void)?
    var onCallTapped: (() -> Void)?

    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(node: ChatNode())
        title = viewModel.roomName
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        node.tableNode.dataSource = self
        node.tableNode.delegate = self
        node.tableNode.view.separatorStyle = .none
        node.tableNode.view.keyboardDismissMode = .interactive
        node.tableNode.view.contentInsetAdjustmentBehavior = .never

        setupNavigationBar()
        bindViewModel()
        bindInput()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            viewModel.cleanup()
        }
    }

    // MARK: - Navigation

    private func setupNavigationBar() {
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "phone.fill"),
            style: .plain,
            target: self,
            action: #selector(callTapped)
        )
    }

    @objc private func backTapped() {
        onBack?()
    }

    @objc private func callTapped() {
        onCallTapped?()
    }

    // MARK: - Bindings

    private func bindViewModel() {
        viewModel.tableDiffsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] diffs in
                self?.applyTableDiffs(diffs)
            }
            .store(in: &cancellables)
    }

    private func applyTableDiffs(_ diffs: [ChatTableDiff]) {
        if diffs.contains(where: { if case .reloadData = $0 { return true }; return false }) {
            node.tableNode.reloadData()
            return
        }

        node.tableNode.performBatch(animated: false, updates: {
            for diff in diffs {
                switch diff {
                case .insertRows(let indexPaths):
                    node.tableNode.insertRows(at: indexPaths, with: .none)
                case .deleteRows(let indexPaths):
                    node.tableNode.deleteRows(at: indexPaths, with: .none)
                case .reloadRows(let indexPaths):
                    node.tableNode.reloadRows(at: indexPaths, with: .none)
                case .reloadData:
                    break
                }
            }
        }, completion: nil)
    }

    private func bindInput() {
        node.inputNode.onSend = { [weak self] text in
            self?.viewModel.sendMessage(text)
        }
    }

    // MARK: - ASTableDataSource

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        viewModel.messages.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let message = viewModel.messages[indexPath.row]
        return {
            switch message.content {
            case .image:
                return ImageMessageCellNode(message: message)
            default:
                return TextMessageCellNode(message: message)
            }
        }
    }

    // MARK: - ASTableDelegate — Batch Fetching (Pagination)

    func shouldBatchFetch(for tableNode: ASTableNode) -> Bool {
        !viewModel.isPaginating
    }

    func tableNode(_ tableNode: ASTableNode, willBeginBatchFetchWith context: ASBatchContext) {
        viewModel.loadOlderMessages()

        viewModel.$isPaginating
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                context.completeBatchFetching(true)
            }
            .store(in: &cancellables)
    }
}
