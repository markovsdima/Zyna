//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG || CHAT_LIST_PLAYGROUND
import AsyncDisplayKit
import Combine
import UIKit

final class ChatListPlaygroundController: ASDKViewController<ASDisplayNode> {
    var onBack: (() -> Void)?
    private let viewModel: ChatViewModel
    private let audioPlayer: AudioPlayerService
    private let preparation = ChatPlaygroundPreparation()
    private let list: ChatPlaygroundCustomList
    private let topBar = GlassNavBar()
    private let inputBar = GlassInputBar()
    private let scrollToLiveButton = AccessibleButtonNode()
    private var gradients: [BubbleGradientRole: BubbleGradientSource] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var rows: [ChatTimelineRow] = []
    private var messageCount = 0
    private var pendingRows: [ChatTimelineRow]?
    private var destination: ChatListDestination = .end
    private var applying = false
    private var paging = false
    private var pageRetryAfter: CFTimeInterval = 0
    private var navigationRevision = 0
    private var measuredWidth: CGFloat = 0
    private var localEdits = false
    private var interactionLocked = false
    private var activeMenu: ContextMenuController?
    private var closed = false
    private var changingWindow = false
    private lazy var fpsBooster = ScrollFPSBooster(hostView: list.captureView)

    init(viewModel: ChatViewModel, audioPlayer: AudioPlayerService) {
        self.viewModel = viewModel
        self.audioPlayer = audioPlayer
        list = ChatPlaygroundCustomList(preparation: preparation)
        super.init(node: ASDisplayNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if !closed { viewModel.cleanup() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        node.backgroundColor = AppColor.chatBackground
        let theme = ChatBubbleThemeStore.shared.selectedTheme
        for role in BubbleGradientRole.allCases {
            let source = BubbleGradientSource(
                colorProvider: { role.colors(traits: $0, outgoingTheme: theme) },
                start: role == .outgoing ? theme.startPoint : .zero,
                end: role == .outgoing ? theme.endPoint : CGPoint(x: 1, y: 1)
            )
            gradients[role] = source
            view.addSubview(source)
        }
        node.addSubnode(list.node)
        node.addSubnode(topBar)
        node.addSubnode(inputBar)
        // GlassInputBar draws the circle and chevron and expands its capture.
        // This node supplies only the hit area and accessibility action.
        scrollToLiveButton.alpha = 0
        scrollToLiveButton.isOpaque = false
        scrollToLiveButton.isAccessibilityElement = true
        scrollToLiveButton.accessibilityLabel = "Scroll to bottom"
        scrollToLiveButton.accessibilityTraits = .button
        scrollToLiveButton.addTarget(
            self, action: #selector(scrollToLiveTapped), forControlEvents: .touchUpInside
        )
        node.addSubnode(scrollToLiveButton)
        inputBar.onScrollButtonLayoutChanged = { [weak self] _, _, tapFrame, tapAlpha in
            self?.scrollToLiveButton.frame = tapFrame
            self?.scrollToLiveButton.alpha = tapAlpha
        }
        topBar.name = "\(viewModel.roomName) · Custom"
        topBar.connectionStatus = "List playground"
        topBar.isTappable = true
        topBar.sourceView = list.captureView
        inputBar.sourceView = list.captureView
        topBar.onBack = { [weak self] in self?.close() }
        topBar.onTitleTapped = { [weak self] in self?.showExperiments() }
        topBar.onCall = { [weak self] in self?.showExperiments() }
        topBar.callButtonNode.accessibilityLabel = "List experiments"
        inputBar.inputNode.onAttachTapped = { [weak self] in self?.showExperiments() }
        inputBar.inputNode.onSend = { [weak self] text, _ in self?.appendLocalMessage(text) }
        inputBar.inputNode.onReplyCancelled = { [weak self] in
            self?.inputBar.inputNode.setReplyPreview(senderName: nil, body: nil)
        }
        // The playground composer exercises layout, not network sending.
        inputBar.inputNode.micButtonNode.isUserInteractionEnabled = false
        list.onScroll = { [weak self] in
            GlassService.shared.setNeedsCapture()
            self?.updateScrollToLiveVisibility()
            self?.prefetchIfNeeded()
        }
        list.onMotionChanged = { [weak self] motion in
            guard let self else { return }
            switch motion {
            case .dragging:
                self.view.endEditing(true)
                self.fpsBooster.stop()
            case .decelerating:
                self.fpsBooster.start()
            case .idle:
                self.fpsBooster.stop()
            }
        }
        viewModel.onTableUpdate = { [weak self] _, origin in
            guard let self, !self.localEdits, !self.changingWindow else { return }
            if origin == .initialLoad { self.destination = .end }
            self.receiveRows()
        }
        viewModel.onInPlaceUpdate = { [weak self] _, _ in self?.receiveRows() }
        viewModel.onOlderHistoryAvailable = { [weak self] in
            self?.pageRetryAfter = 0
            self?.prefetchIfNeeded()
        }
        viewModel.$isGroupChat.removeDuplicates().sink { [weak self] _ in
            self?.receiveRows()
        }.store(in: &cancellables)
        receiveRows()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for source in gradients.values { source.frame = view.bounds }
        topBar.updateLayout(in: view)
        inputBar.updateLayout(in: view)
        list.updateViewport(size: view.bounds.size, insets: UIEdgeInsets(
            top: topBar.coveredHeight + 8, left: 0,
            bottom: inputBar.coveredHeight + 8, right: 0
        ))
        updateScrollToLiveVisibility()
        if view.bounds.width > 0, measuredWidth != view.bounds.width {
            pendingRows = localEdits ? rows : Array(viewModel.rows.reversed())
            applyNext()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.captureFor(duration: 0.5)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        fpsBooster.stop()
        if isMovingFromParent || isBeingDismissed { finish() }
    }

    private func close() {
        finish()
        onBack?()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        pendingRows = nil
        activeMenu?.dismissMenu()
        fpsBooster.stop()
        viewModel.cleanup()
    }

    private func receiveRows() {
        guard isViewLoaded, !closed, !localEdits, !changingWindow else { return }
        pendingRows = Array(viewModel.rows.reversed())
        applyNext()
    }

    private func applyNext() {
        guard !closed, !applying, !interactionLocked, activeMenu == nil,
              view.bounds.width > 0, let nextRows = pendingRows else { return }
        pendingRows = nil
        applying = true
        let requestRevision = navigationRevision
        let requestDestination = destination
        destination = .preserve
        let width = view.bounds.width
        // Resolve UIKit/controller state before entering the layout worker.
        var seen = Set<String>()
        let items = nextRows.compactMap { row -> ChatPlaygroundItem? in
            let id = ChatPlaygroundItem.id(for: row)
            guard seen.insert(id).inserted else {
                assertionFailure("Duplicate playground row identity")
                return nil
            }
            return makeItem(row: row, id: id)
        }
        preparation.prepare(items, width: width) { [weak self] snapshot in
            guard let self, !self.closed else { return }
            guard self.navigationRevision == requestRevision, self.view.bounds.width == width else {
                self.applying = false
                if self.pendingRows == nil { self.pendingRows = nextRows }
                self.applyNext()
                return
            }
            // Menu extraction must retain its source geometry until return.
            guard !self.interactionLocked, self.activeMenu == nil else {
                self.applying = false
                if self.pendingRows == nil { self.pendingRows = nextRows }
                self.destination = requestDestination
                return
            }
            self.rows = snapshot.items.map(\.row)
            self.messageCount = self.rows.reduce(0) { $0 + ($1.message == nil ? 0 : 1) }
            self.measuredWidth = width
            self.list.apply(snapshot, destination: requestDestination) { [weak self] in
                guard let self else { return }
                self.applying = false
                self.applyNext()
                self.prefetchIfNeeded()
                GlassService.shared.setNeedsCapture()
            }
        }
    }

    private func prefetchIfNeeded() {
        guard !closed, !localEdits, !applying, !paging, !interactionLocked,
              activeMenu == nil, !rows.isEmpty, CACurrentMediaTime() >= pageRetryAfter else { return }
        let limits = list.geometry.limits(viewport: view.bounds.height, insets: list.insets)
        guard let direction = ChatHistoryPageLoader.prefetchDirection(
            olderRemaining: list.offset - limits.lowerBound,
            newerRemaining: limits.upperBound - list.offset,
            viewportHeight: view.bounds.height,
            hasOlder: viewModel.hasOlderInDB, hasNewer: !viewModel.isAtLiveEdge
        ) else { return }
        paging = true
        viewModel.loadHistoryPage(direction) { [weak self] result in
            guard let self, !self.closed else { return }
            self.paging = false
            if result != .applied { self.pageRetryAfter = CACurrentMediaTime() + 0.5 }
            // onTableUpdate has already queued the matching snapshot.
            self.applyNext()
            if !self.applying, result == .applied { self.prefetchIfNeeded() }
            if result == .superseded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.prefetchIfNeeded()
                }
            }
        }
    }

    private func makeItem(row: ChatTimelineRow, id: String) -> ChatPlaygroundItem {
        let audioPlayer = audioPlayer
        let roomID = viewModel.roomIdentifier
        let roomName = viewModel.roomName
        let group = viewModel.isGroupChat
        let source = row.message.flatMap { message in
            message.zynaAttributes.color == nil ? gradients[message.isOutgoing ? .outgoing : .incoming] : nil
        }
        let rendered = row.message.map {
            group && !$0.isOutgoing
                ? $0.applyingProfileAppearance(ProfileAppearanceService.shared.cachedAppearance(userId: $0.senderId))
                : $0
        }
        return ChatPlaygroundItem(id: id, row: row, makeNode: { [weak self] in
            let content: ASCellNode
            if case .dateDivider(let date) = row {
                content = DateDividerCellNode(model: date)
            } else if let message = rendered {
                if case .callEvent = message.content {
                    content = CallEventCellNode(message: message)
                } else if case .matrixRTCCall = message.content {
                    content = MatrixRTCCallEventCellNode(message: message, isDirect: !group, currentUserId: "")
                } else if case .systemEvent = message.content {
                    content = StateEventCellNode(message: message)
                } else if message.mediaGroupPresentation?.hidesStandaloneBubble == true {
                    let placeholder = ASCellNode()
                    placeholder.style.preferredSize = CGSize(width: 1, height: 0.01)
                    content = placeholder
                } else {
                    let cell: MessageCellNode
                    if message.mediaGroupPresentation?.rendersCompositeBubble == true {
                        cell = PhotoGroupMessageCellNode(message: message, isGroupChat: group)
                    } else {
                        switch message.content {
                        case .image: cell = ImageMessageCellNode(message: message, isGroupChat: group)
                        case .video: cell = VideoMessageCellNode(message: message, isGroupChat: group)
                        case .file: cell = FileCellNode(message: message, isGroupChat: group)
                        case .voice:
                            cell = VoiceMessageCellNode(
                                message: message, audioPlayer: audioPlayer,
                                roomId: roomID, roomName: roomName, isGroupChat: group
                            )
                        default: cell = TextMessageCellNode(message: message, isGroupChat: group)
                        }
                    }
                    cell.bubbleGradientSource = source
                    cell.onInteractionLockChanged = { [weak self] locked in
                        guard let self else { return }
                        self.interactionLocked = locked
                        self.list.scrollView.isScrollEnabled = !locked && self.activeMenu == nil
                        if !locked { self.applyNext() }
                    }
                    cell.onContextMenuActivated = { [weak self, weak cell] point in
                        guard let cell else { return }
                        self?.showMenu(message: message, cell: cell, point: point)
                    }
                    cell.onReplyHeaderTapped = { [weak self] eventID in self?.jump(eventID: eventID) }
                    cell.onReplySwipeActivated = { [weak self] in self?.reply(to: message) }
                    content = cell
                }
            } else {
                content = ASCellNode()
            }
            return ChatPlaygroundRowNode(id: id, content: content)
        }, configuration: group ? 1 : 0)
    }

    private func showMenu(message: ChatMessage, cell: MessageCellNode, point: CGPoint) {
        guard activeMenu == nil, let window = view.window,
              let extracted = cell.extractBubbleForMenu(in: window.coordinateSpace) else { return }
        let menu = ContextMenuController(
            contentNode: extracted.node, sourceFrame: extracted.frame,
            contentPath: { cell.contextMenuContentPath() }, captureView: list.captureView,
            actions: [
                ContextMenuAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] in
                    self?.reply(to: message)
                },
                ContextMenuAction(title: "Change height locally", image: UIImage(systemName: "arrow.up.and.down")) { [weak self] in
                    self?.changeHeight(message)
                },
                ContextMenuAction(title: "Remove locally", image: UIImage(systemName: "trash")) { [weak self] in
                    self?.removeLocally(message)
                }
            ]
        )
        menu.onDismissComplete = { [weak self] in
            cell.restoreBubbleFromMenu()
            self?.activeMenu = nil
            self?.interactionLocked = false
            self?.list.scrollView.isScrollEnabled = true
            self?.applyNext()
        }
        cell.onDragChanged = { [weak menu] in menu?.trackFinger(at: $0) }
        cell.onDragEnded = { [weak menu] in menu?.releaseFinger(at: $0) }
        activeMenu = menu
        list.scrollView.isScrollEnabled = false
        menu.show(in: window)
    }

    private func reply(to message: ChatMessage) {
        inputBar.inputNode.setReplyPreview(
            senderName: message.senderDisplayName ?? message.senderId,
            body: message.content.textPreview
        )
    }

    private func jump(eventID: String) {
        if let row = rows.first(where: { $0.message?.eventId == eventID }) {
            list.scroll(to: .item(ChatPlaygroundItem.id(for: row)))
            return
        }
        navigationRevision += 1
        localEdits = false
        destination = .item("message:" + eventID)
        changingWindow = true
        viewModel.jumpToMessage(eventId: eventID)
        // A composite may use its group ID rather than its Matrix event ID.
        if let row = viewModel.rows.first(where: {
            $0.message?.eventId == eventID
                || $0.message?.mediaGroupPresentation?.items.contains(where: { $0.eventId == eventID }) == true
        }) {
            destination = .item(ChatPlaygroundItem.id(for: row))
        }
        changingWindow = false
        receiveRows()
    }

    private func showExperiments() {
        let sheet = UIAlertController(
            title: "Custom playground",
            message: "Real chat cells and glass. Composer and test edits are local.",
            preferredStyle: .actionSheet
        )
        func action(_ title: String, _ perform: @escaping () -> Void) {
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in perform() })
        }
        action("Jump to oldest stored message") { [weak self] in self?.jumpToEdge(latest: false) }
        action("Jump to latest") { [weak self] in self?.jumpToEdge(latest: true) }
        action("Insert 30 earlier rows in 2 seconds") { [weak self] in self?.scheduleInsertion(earlier: true) }
        action("Insert 30 newer rows in 2 seconds") { [weak self] in self?.scheduleInsertion(earlier: false) }
        action("Change visible bubble height in 2 seconds") { [weak self] in
            self?.scheduleVisibleMutation(remove: false)
        }
        action("Remove visible bubble in 2 seconds") { [weak self] in
            self?.scheduleVisibleMutation(remove: true)
        }
        action("Reset local edits") { [weak self] in
            guard let self else { return }
            self.navigationRevision += 1
            self.localEdits = false
            self.destination = .preserve
            self.topBar.connectionStatus = "List playground"
            self.receiveRows()
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = topBar.view
        present(sheet, animated: true)
    }

    private func jumpToEdge(latest: Bool) {
        navigationRevision += 1
        localEdits = false
        destination = latest ? .end : .start
        changingWindow = true
        if latest { viewModel.jumpToLive() } else { viewModel.jumpToOldest() }
        changingWindow = false
        receiveRows()
    }

    private func updateScrollToLiveVisibility() {
        guard !closed, !rows.isEmpty else {
            inputBar.scrollButtonVisible = false
            return
        }
        let limits = list.geometry.limits(viewport: view.bounds.height, insets: list.insets)
        // Match the production chat's 1.5-screen / 20-message threshold.
        // Custom uses logical coordinates, not its recentered UIScrollView.
        let scrolledFar = limits.upperBound - list.offset > view.bounds.height * 1.5
        let hasNewerHistory = !localEdits && !viewModel.isAtLiveEdge
        inputBar.scrollButtonVisible = hasNewerHistory || (scrolledFar && messageCount > 20)
    }

    @objc private func scrollToLiveTapped() {
        guard !closed, !interactionLocked, activeMenu == nil else { return }
        if localEdits || viewModel.isAtLiveEdge {
            // Keep local edits and loaded history. Also retarget any snapshot
            // still being prepared so its older destination cannot undo the tap.
            navigationRevision += 1
            destination = .end
            if pendingRows == nil { pendingRows = rows }
            applyNext()
            list.scroll(to: .end)
        } else {
            jumpToEdge(latest: true)
        }
        inputBar.scrollButtonVisible = false
    }

    private func scheduleInsertion(earlier: Bool) {
        let revision = navigationRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.closed, self.navigationRevision == revision else { return }
            let batch = (0..<30).map { index in
                ChatTimelineRow.message(Self.localMessage(
                    text: "Local \(earlier ? "earlier" : "newer") row \(index + 1)\n"
                        + String(repeating: "Measured with a real bubble. ", count: index % 5 + 1),
                    outgoing: index % 2 == 0
                ))
            }
            self.submitLocal(earlier ? batch + self.rows : self.rows + batch)
        }
    }

    private func scheduleVisibleMutation(remove: Bool) {
        let revision = navigationRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.closed, self.navigationRevision == revision else { return }
            let visible = self.list.geometry.range(in: CGRect(
                x: 0, y: self.list.offset + self.list.insets.top,
                width: 1, height: max(1, self.view.bounds.height - self.list.insets.top - self.list.insets.bottom)
            ))
            // Texture may still be committing the previous snapshot. Resolve
            // the visible IDs instead of indexing the pending datasource.
            let byID = Dictionary(uniqueKeysWithValues: self.rows.map {
                (ChatPlaygroundItem.id(for: $0), $0)
            })
            guard let message = visible.compactMap({
                byID[self.list.geometry.ids[$0]]?.message
            }).first else { return }
            if remove { self.removeLocally(message) } else { self.changeHeight(message) }
        }
    }

    private func appendLocalMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputBar.inputNode.setCurrentText("")
        submitLocal(rows + [.message(Self.localMessage(text: text, outgoing: true))], destination: .end)
    }

    private func changeHeight(_ message: ChatMessage) {
        let id = ChatPlaygroundItem.id(for: .message(message))
        let body = message.content.textPreview
        let text = body.count > 500 ? "Short local replacement" : String(repeating: body + "\n", count: 8)
        submitLocal(rows.map {
            ChatPlaygroundItem.id(for: $0) == id
                ? .message(Self.localMessage(text: text, outgoing: message.isOutgoing, replacing: message))
                : $0
        })
    }

    private func removeLocally(_ message: ChatMessage) {
        let id = ChatPlaygroundItem.id(for: .message(message))
        submitLocal(rows.filter { ChatPlaygroundItem.id(for: $0) != id })
    }

    private func submitLocal(_ rows: [ChatTimelineRow], destination: ChatListDestination = .preserve) {
        navigationRevision += 1
        localEdits = true
        topBar.connectionStatus = "Local edits · tap title to reset"
        pendingRows = rows
        self.destination = destination
        applyNext()
    }

    static func localMessage(text: String, outgoing: Bool, replacing old: ChatMessage? = nil) -> ChatMessage {
        ChatMessage(
            id: old?.id ?? "playground:" + UUID().uuidString,
            eventId: old?.eventId, transactionId: old?.transactionId, itemIdentifier: nil,
            senderId: old?.senderId ?? "@playground:local",
            senderDisplayName: old?.senderDisplayName ?? "Playground",
            senderAvatarUrl: old?.senderAvatarUrl,
            isOutgoing: outgoing, timestamp: old?.timestamp ?? Date(),
            content: .text(body: text), reactions: [], replyInfo: old?.replyInfo,
            isEditable: false, isEdited: old != nil, isEditPending: false,
            isEditFailed: false, latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced"
        )
    }
}
#endif
