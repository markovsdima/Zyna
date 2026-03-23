//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import PhotosUI
//import UniformTypeIdentifiers

final class ChatViewController: ASDKViewController<ChatNode>, ASTableDataSource, ASTableDelegate {

    var onBack: (() -> Void)?
    var onCallTapped: (() -> Void)?
    var onTitleTapped: ((String) -> Void)?

    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()
    private var batchFetchCancellable: AnyCancellable?
    private let presenceTitleView = PresenceTitleView()
    private let glassInputBar = GlassInputBar()
    private let audioPlayer = AudioPlayerService()
    private var activeContextMenu: ContextMenuController?
    private var pendingRedactedIds: [String] = []
    private var isPickerPresented = false
    private var interactionLocks = Set<String>()
    private lazy var fpsBooster = ScrollFPSBooster(hostView: node.tableNode.view)

    // MARK: - Init

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(node: ChatNode())
        presenceTitleView.name = viewModel.roomName
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
        node.tableNode.view.showsVerticalScrollIndicator = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(tableTapped))
        tap.cancelsTouchesInView = false
        node.tableNode.view.addGestureRecognizer(tap)

        setupNavigationBar()
        bindViewModel()
        bindInput()

        // Glass input bar
        view.addSubview(glassInputBar)

        // Pre-set inset
        let estimatedBarHeight: CGFloat = 49 + DeviceInsets.bottom
        node.tableNode.contentInset.top = estimatedBarHeight
        node.tableNode.view.verticalScrollIndicatorInsets.top = estimatedBarHeight
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let navBottom = navigationController?.navigationBar.frame.maxY ?? 0
        node.tableNode.contentInset.bottom = navBottom

        glassInputBar.updateLayout(in: view)
        node.tableNode.contentInset.top = glassInputBar.coveredHeight
        node.tableNode.view.verticalScrollIndicatorInsets.top = glassInputBar.coveredHeight
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        navigationItem.scrollEdgeAppearance = appearance

        navigationItem.titleView = presenceTitleView

        viewModel.$partnerPresence
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presence in
                self?.presenceTitleView.presence = presence
            }
            .store(in: &cancellables)

        viewModel.$partnerUserId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userId in
                self?.presenceTitleView.isTappable = userId != nil
            }
            .store(in: &cancellables)

        presenceTitleView.onTapped = { [weak self] in
            guard let userId = self?.viewModel.partnerUserId else { return }
            self?.onTitleTapped?(userId)
        }

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

        viewModel.onRedactedDetected = { [weak self] messageIds in
            self?.handleRedactedMessages(messageIds)
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
        glassInputBar.inputNode.onSend = { [weak self] text in
            self?.viewModel.sendMessage(text)
        }

        glassInputBar.inputNode.onVoiceRecordingFinished = { [weak self] fileURL, duration, waveform in
            self?.viewModel.sendVoiceMessage(fileURL: fileURL, duration: duration, waveform: waveform)
        }

        glassInputBar.inputNode.onAttachTapped = { [weak self] in
            self?.presentPhotoPicker()
        }
    }

    @objc private func tableTapped() {
        glassInputBar.inputNode.textInputNode.resignFirstResponder()
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

        var actions = [
            ContextMenuAction(
                title: "Reply",
                image: UIImage(systemName: "arrowshape.turn.up.left"),
                handler: { print("[context-menu] Reply tapped: \(message.id)") }
            )
        ]

        if message.itemIdentifier != nil && !message.content.isRedacted {
            actions.append(ContextMenuAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                isDestructive: true,
                handler: { [weak self] in
                    self?.triggerPaintSplashDelete(for: message)
                }
            ))
        }

        let menuVC = ContextMenuController(
            contentNode: info.node,
            sourceFrame: info.frame,
            actions: actions
        )
        menuVC.onDismissComplete = { [weak self, weak cellNode] in
            cellNode?.restoreBubbleFromMenu()
            self?.unlockInteraction("contextMenu")
            self?.activeContextMenu = nil
            self?.flushPendingRedactions()
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

    // MARK: - Scroll

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate {
            fpsBooster.start()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        fpsBooster.stop()
    }

    // MARK: - Paint Splash Delete

    private func triggerPaintSplashDelete(for message: ChatMessage) {
        viewModel.redactMessage(message)
    }

    private func handleRedactedMessages(_ messageIds: [String]) {
        // Defer if context menu is active (bubble is reparented to overlay)
        if activeContextMenu != nil {
            pendingRedactedIds.append(contentsOf: messageIds)
            return
        }

        for messageId in messageIds {
            guard let row = viewModel.messages.firstIndex(where: { $0.id == messageId }) else {
                viewModel.hideMessage(messageId)
                continue
            }

            let indexPath = IndexPath(row: row, section: 0)

            // If cell is off-screen, hide immediately without animation
            guard let cellNode = node.tableNode.nodeForRow(at: indexPath) as? MessageCellNode,
                  cellNode.isNodeLoaded else {
                viewModel.hideMessage(messageId)
                continue
            }

            PaintSplashTrigger.trigger(in: node.tableNode, at: indexPath) { [weak self] in
                self?.viewModel.hideMessage(messageId)
            }
        }
    }

    private func flushPendingRedactions() {
        guard !pendingRedactedIds.isEmpty else { return }
        let ids = pendingRedactedIds
        pendingRedactedIds.removeAll()
        handleRedactedMessages(ids)
    }

    private func indexPathForMessage(_ message: ChatMessage) -> IndexPath? {
        guard let row = viewModel.messages.firstIndex(where: { $0.id == message.id }) else {
            return nil
        }
        return IndexPath(row: row, section: 0)
    }

    // MARK: - Photo Picker

    private func presentPhotoPicker() {
        isPickerPresented = true
        var config = PHPickerConfiguration()
        config.selectionLimit = 10
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
}

// MARK: - PHPickerViewControllerDelegate

extension ChatViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.isPickerPresented = false
            self.becomeFirstResponder()
        }
        guard !results.isEmpty else { return }

        let captionText = glassInputBar.inputNode.textInputNode.textView.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = (captionText?.isEmpty == false) ? captionText : nil
        if caption != nil {
            glassInputBar.inputNode.textInputNode.textView.text = ""
        }

        Task {
            var processed: [ProcessedImage] = []
            for result in results {
                guard let data = await loadImageData(from: result) else { continue }
                if let image = try? await MediaPreprocessor.processImage(from: data) {
                    processed.append(image)
                }
            }
            guard !processed.isEmpty else { return }
            await MainActor.run {
                viewModel.sendImages(processed, caption: caption)
            }
        }
    }

    private func loadImageData(from result: PHPickerResult) async -> Data? {
        await withCheckedContinuation { continuation in
            result.itemProvider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
