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
    private let inputAccessory = ChatInputAccessoryView()

    // MARK: - InputAccessoryView

    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? { inputAccessory }

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

        let tap = UITapGestureRecognizer(target: self, action: #selector(tableTapped))
        tap.cancelsTouchesInView = false
        node.tableNode.view.addGestureRecognizer(tap)

        setupNavigationBar()
        bindViewModel()
        bindInput()
        observeKeyboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
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
        viewModel.onTableUpdate = { [weak self] update in
            self?.applyTableUpdate(update)
        }
    }

    private func applyTableUpdate(_ update: TableUpdate) {
        switch update {
        case .reload:
            node.tableNode.reloadData()
        case .batch(let deletions, let insertions, let updates):
            if deletions.isEmpty && insertions.isEmpty && updates.isEmpty { return }
            node.tableNode.performBatch(animated: false, updates: {
                if !deletions.isEmpty { node.tableNode.deleteRows(at: deletions, with: .none) }
                if !insertions.isEmpty { node.tableNode.insertRows(at: insertions, with: .none) }
                if !updates.isEmpty { node.tableNode.reloadRows(at: updates, with: .none) }
            }, completion: nil)
        }
    }

    private func bindInput() {
        inputAccessory.inputNode.onSend = { [weak self] text in
            self?.viewModel.sendMessage(text)
        }
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func tableTapped() {
        inputAccessory.inputNode.textInputNode.resignFirstResponder()
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // How much of the screen the keyboard (+ accessory) covers
        let coveredHeight = max(0, UIScreen.main.bounds.height - endFrame.origin.y)
        // Inverted table: contentInset.top is the visual bottom
        node.tableNode.contentInset.top = coveredHeight
        node.tableNode.view.verticalScrollIndicatorInsets.top = coveredHeight
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
