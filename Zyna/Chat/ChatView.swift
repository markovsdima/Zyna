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
    private var batchFetchCancellable: AnyCancellable?
    private let inputAccessory = ChatInputAccessoryView()
    private let audioPlayer = AudioPlayerService()
    private var activeContextMenu: ContextMenuController?
    private var interactionLocks = Set<String>()
    private lazy var fpsBooster = ScrollFPSBooster(hostView: node.tableNode.view)

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

        // Pre-set inset to the expected accessory height so the table
        // doesn't visibly slide up when the keyboard notification arrives.
        let estimatedAccessoryHeight: CGFloat = 49 + DeviceInsets.bottom
        node.tableNode.contentInset.top = estimatedAccessoryHeight
        node.tableNode.view.verticalScrollIndicatorInsets.top = estimatedAccessoryHeight

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
            audioPlayer.stop()
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
        case .batch(let deletions, let insertions, let updates, let animated):
            if deletions.isEmpty && insertions.isEmpty && updates.isEmpty { return }
            let rowAnimation: UITableView.RowAnimation = animated ? .automatic : .none
            node.tableNode.performBatch(animated: animated, updates: {
                if !deletions.isEmpty { node.tableNode.deleteRows(at: deletions, with: rowAnimation) }
                if !insertions.isEmpty { node.tableNode.insertRows(at: insertions, with: rowAnimation) }
                if !updates.isEmpty { node.tableNode.reloadRows(at: updates, with: .none) }
            }, completion: nil)
        }
    }

    private func bindInput() {
        inputAccessory.inputNode.onSend = { [weak self] text in
            self?.viewModel.sendMessage(text)
        }

        inputAccessory.inputNode.onVoiceRecordingFinished = { [weak self] fileURL, duration, waveform in
            // Convert Float waveform (0...1) to UInt16 (0...1024) for Matrix SDK
            let sdkWaveform = waveform.map { UInt16(min(max($0, 0), 1) * 1024) }
            self?.viewModel.sendVoiceMessage(fileURL: fileURL, duration: duration, waveform: sdkWaveform)
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
        guard !isMovingFromParent,
              navigationController?.transitionCoordinator == nil,
              let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
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
        let messages = viewModel.messages
        guard indexPath.row < messages.count else {
            return { ASCellNode() }
        }
        let message = messages[indexPath.row]
        let audioPlayer = self.audioPlayer
        return { [weak self] in
            let cellNode: MessageCellNode
            switch message.content {
            case .voice:
                cellNode = VoiceMessageCellNode(message: message, audioPlayer: audioPlayer)
            case .image:
                cellNode = ImageMessageCellNode(message: message)
            default:
                cellNode = TextMessageCellNode(message: message)
            }

            cellNode.onInteractionLockChanged = { [weak self] locked in
                if locked {
                    self?.lockInteraction("contextMenu")
                } else {
                    self?.unlockInteraction("contextMenu")
                }
            }

            cellNode.onContextMenuActivated = { [weak self, weak cellNode] in
                guard let self, let cellNode else { return }
                self.presentContextMenu(for: message, from: cellNode)
            }

            cellNode.onReactionTapped = { [weak self] key in
                self?.viewModel.toggleReaction(key, for: message)
            }

            return cellNode
        }
    }

    // MARK: - Context Menu

    private func presentContextMenu(for message: ChatMessage, from cellNode: ContextMenuCellNode) {
        guard let window = view.window,
              let info = cellNode.extractBubbleForMenu(in: window.coordinateSpace) else { return }

        let actions = [
            ContextMenuAction(
                title: "Reply",
                image: UIImage(systemName: "arrowshape.turn.up.left"),
                handler: { print("[context-menu] Reply tapped: \(message.id)") }
            ),
            ContextMenuAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                isDestructive: true,
                handler: { print("[context-menu] Delete tapped: \(message.id)") }
            )
        ]

        let menuVC = ContextMenuController(
            contentNode: info.node,
            sourceFrame: info.frame,
            actions: actions
        )
        menuVC.onDismissComplete = { [weak self, weak cellNode] in
            cellNode?.restoreBubbleFromMenu()
            self?.unlockInteraction("contextMenu")
            self?.activeContextMenu = nil
        }

        menuVC.onReactionSelected = { [weak self] emoji in
            self?.viewModel.toggleReaction(emoji, for: message)
        }

        cellNode.onDragChanged = { [weak menuVC] point in
            menuVC?.trackFinger(at: point)
        }
        cellNode.onDragEnded = { [weak menuVC] point in
            menuVC?.releaseFinger(at: point)
        }

        activeContextMenu = menuVC
        menuVC.show(in: window)
    }

    // MARK: - Interaction Lock

    func lockInteraction(_ token: String) {
        let wasEmpty = interactionLocks.isEmpty
        interactionLocks.insert(token)
        if wasEmpty {
            node.tableNode.view.isScrollEnabled = false
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        }
    }

    func unlockInteraction(_ token: String) {
        interactionLocks.remove(token)
        if interactionLocks.isEmpty {
            node.tableNode.view.isScrollEnabled = true
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }

    // MARK: - ASTableDelegate — Batch Fetching (Pagination)

    func shouldBatchFetch(for tableNode: ASTableNode) -> Bool {
        !viewModel.isPaginating
    }

    func tableNode(_ tableNode: ASTableNode, willBeginBatchFetchWith context: ASBatchContext) {
        viewModel.loadOlderMessages()

        batchFetchCancellable = viewModel.$isPaginating
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                context.completeBatchFetching(true)
                self?.batchFetchCancellable = nil
            }
    }

    // MARK: - 120fps Scroll Boost

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate {
            fpsBooster.start()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        fpsBooster.stop()
    }
}
