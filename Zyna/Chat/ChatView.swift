//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import MatrixRustSDK

final class ChatViewController: ASDKViewController<ChatNode>, ASTableDataSource, ASTableDelegate {

    var onBack: (() -> Void)?
    var onCallTapped: (() -> Void)?
    var onTitleTapped: ((String) -> Void)?
    var onRoomDetailsTapped: (() -> Void)?
    var onForwardMessage: ((ChatMessage) -> Void)?

    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()
    private var batchFetchCancellable: AnyCancellable?
    private let glassNavBar = GlassNavBar()
    private let glassInputBar = GlassInputBar()
    private let searchBar = SearchBarView()
    private let inviteBanner = InviteBannerView()

    /// Scroll-to-live button lives at node.view level (not inside input bar)
    /// so its tap target works even when positioned above the bar's bounds.
    /// The glass circle itself is rendered by GlassInputBar's shader
    /// (shape3, metaball with mic). These are just the chevron + tap area.
    private let scrollButtonIcon = UIImageView()
    private let scrollButtonTap = UIButton(type: .custom)
    
    /// Flip to `true` to show Apple vs Custom glass comparison overlay (iOS 26+)
    private static let showGlassComparison = false

    // TODO: dial in via side-by-side gesture comparison — current values
    // are a reasonable starting point, not a final choice.
    /// Release-velocity threshold (pt/ms) a drag must exceed to dismiss the keyboard.
    private static let keyboardDismissVelocity: CGFloat = 1.0
    /// Minimum scroll distance (pt). Paired with the velocity threshold above.
    private static let keyboardDismissDistance: CGFloat = 80

    private var dragStartOffsetY: CGFloat = 0

    private lazy var glassComparison = GlassComparisonView()
    private lazy var glassTuning = GlassTuningView()
    private let audioPlayer = AudioPlayerService()
    private var activeContextMenu: ContextMenuController?
    private var pendingRedactedIds: [String] = []
    private var isTeleporting = false
    private var isPickerPresented = false
    private var interactionLocks = Set<String>()
    private lazy var fpsBooster = ScrollFPSBooster(hostView: node.tableNode.view)

    // MARK: - Init

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(node: ChatNode())
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
        node.tableNode.view.keyboardDismissMode = .none
        node.tableNode.view.contentInsetAdjustmentBehavior = .never
        node.tableNode.view.showsVerticalScrollIndicator = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(tableTapped))
        tap.cancelsTouchesInView = false
        // Cells' ContextSourceNode installs a zero-duration long-press
        // that would otherwise swallow the tap — recognize simultaneously.
        tap.delegate = self
        // Let the scroll pan take precedence: a flick that starts a scroll
        // shouldn't also register as a dismissing tap.
        tap.require(toFail: node.tableNode.view.panGestureRecognizer)
        node.tableNode.view.addGestureRecognizer(tap)

        setupNavigationBar()
        bindViewModel()
        bindInput()

        // Glass nav bar (replaces system nav bar)
        glassNavBar.name = viewModel.roomName
        glassNavBar.onBack = { [weak self] in self?.onBack?() }
        glassNavBar.onCall = { [weak self] in self?.onCallTapped?() }
        glassNavBar.onTitleTapped = { [weak self] in
            guard let self else { return }
            if let userId = self.viewModel.partnerUserId {
                self.onTitleTapped?(userId)
            } else {
                self.onRoomDetailsTapped?()
            }
        }
        node.addSubnode(glassNavBar)
        node.glassNavBar = glassNavBar

        // Search bar (hidden by default)
        searchBar.isHidden = true
        searchBar.onQueryChanged = { [weak self] text in
            self?.viewModel.updateSearchQuery(text)
        }
        searchBar.onNext = { [weak self] in
            self?.viewModel.nextSearchResult()
            self?.navigateToCurrentSearchResult()
        }
        searchBar.onPrevious = { [weak self] in
            self?.viewModel.previousSearchResult()
            self?.navigateToCurrentSearchResult()
        }
        searchBar.onCancel = { [weak self] in
            self?.deactivateSearch()
        }
        view.addSubview(searchBar)

        // Invite banner (hidden by default)
        inviteBanner.isHidden = !viewModel.isInvited
        inviteBanner.onAccept = { [weak self] in
            self?.viewModel.acceptInvite()
        }
        view.addSubview(inviteBanner)

        // Glass input bar
        glassInputBar.isHidden = viewModel.isInvited
        node.addSubnode(glassInputBar)
        node.glassInputBar = glassInputBar

        // Scroll-to-live button — lives on node.view so its tap target
        // works when positioned above the input bar's bounds.
        scrollButtonIcon.image = AppIcon.chevronDown.rendered(size: 24, color: .gray)
        scrollButtonIcon.contentMode = .center
        scrollButtonIcon.alpha = 0
        scrollButtonIcon.isUserInteractionEnabled = false
        node.view.addSubview(scrollButtonIcon)

        scrollButtonTap.alpha = 0
        scrollButtonTap.accessibilityLabel = "Scroll to bottom"
        scrollButtonTap.accessibilityTraits = .button
        scrollButtonTap.addTarget(self, action: #selector(scrollToLiveTapped), for: .touchUpInside)
        node.view.addSubview(scrollButtonTap)
        node.scrollButtonTap = scrollButtonTap

        // Both glass bars capture from the table — no self-capture
        glassNavBar.sourceView = node.tableNode.view
        glassInputBar.sourceView = node.tableNode.view

        if Self.showGlassComparison {
            glassComparison.sourceView = node.tableNode.view
            view.addSubview(glassComparison)
            view.addSubview(glassTuning)
        }


        // Pre-set inset
        let estimatedBarHeight: CGFloat = 49 + DeviceInsets.bottom
        node.tableNode.contentInset.top = estimatedBarHeight
        node.tableNode.view.verticalScrollIndicatorInsets.top = estimatedBarHeight
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        glassNavBar.updateLayout(in: view)
        searchBar.frame = CGRect(
            x: 0, y: glassNavBar.coveredHeight,
            width: view.bounds.width, height: 44
        )
        inviteBanner.frame = CGRect(
            x: 0, y: glassNavBar.coveredHeight,
            width: view.bounds.width, height: 44
        )
        if Self.showGlassComparison {
            glassComparison.updateLayout(in: view)
            glassTuning.frame = CGRect(
                x: 12,
                y: glassComparison.frame.maxY + 8,
                width: 170,
                height: CGFloat(5 * 32 + 16)
            )
        }
        node.tableNode.contentInset.bottom = glassNavBar.coveredHeight

        glassInputBar.updateLayout(in: view)
        node.tableNode.contentInset.top = glassInputBar.coveredHeight
        node.tableNode.view.verticalScrollIndicatorInsets.top = glassInputBar.coveredHeight
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Force glass recapture after navigation push completes
        GlassService.shared.setNeedsCapture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            audioPlayer.stop()
            viewModel.cleanup()
        }
    }

    // MARK: - Navigation

    private func setupNavigationBar() {
        navigationController?.setNavigationBarHidden(true, animated: false)

        viewModel.$partnerPresence
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presence in
                self?.glassNavBar.presence = presence
            }
            .store(in: &cancellables)

        viewModel.$partnerUserId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userId in
                if userId != nil { self?.glassNavBar.isTappable = true }
            }
            .store(in: &cancellables)

        viewModel.$memberCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.glassNavBar.memberCount = count
                if count != nil { self?.glassNavBar.isTappable = true }
            }
            .store(in: &cancellables)

        viewModel.$searchState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, let state else { return }
                self.searchBar.updateStatus(state.statusText, hasResults: !state.results.isEmpty)
            }
            .store(in: &cancellables)
    }

    // MARK: - Search

    func activateSearch() {
        viewModel.activateSearch()
        searchBar.isHidden = false
        searchBar.activate()
    }

    private func deactivateSearch() {
        viewModel.deactivateSearch()
        searchBar.isHidden = true
    }

    private func navigateToCurrentSearchResult() {
        guard let result = viewModel.searchState?.currentResult else { return }
        navigateToMessage(eventId: result.eventId)
    }

    // MARK: - Bindings

    private func bindViewModel() {
        viewModel.onTableUpdate = { [weak self] update in
            self?.applyTableUpdate(update)
        }

        viewModel.onInPlaceUpdate = { [weak self] indexPath, message in
            guard let self,
                  let cellNode = self.node.tableNode.nodeForRow(at: indexPath) as? MessageCellNode
            else { return }
            cellNode.updateSendStatus(message.sendStatus)
        }

        viewModel.onRedactedDetected = { [weak self] messageIds in
            self?.handleRedactedMessages(messageIds)
        }

        viewModel.$isInvited
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invited in
                guard let self else { return }
                self.inviteBanner.isHidden = !invited
                self.glassInputBar.isHidden = invited
            }
            .store(in: &cancellables)

        viewModel.$replyingTo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.glassInputBar.inputNode.setReplyPreview(
                    senderName: message?.senderDisplayName ?? message?.senderId,
                    body: message?.content.textPreview
                )
            }
            .store(in: &cancellables)

        viewModel.$pendingForwardContent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] forward in
                guard let self else { return }
                if let forward {
                    self.glassInputBar.inputNode.setForwardPreview(
                        senderName: forward.preview.senderDisplayName ?? forward.preview.senderId,
                        body: forward.preview.content.textPreview
                    )
                } else {
                    self.glassInputBar.inputNode.setForwardPreview(senderName: nil, body: nil)
                }
            }
            .store(in: &cancellables)
    }

    private func applyTableUpdate(_ update: TableUpdate) {
        if isTeleporting {
            // During teleportation: silent reload, no animations
            node.tableNode.reloadData()
            return
        }
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
        glassInputBar.inputNode.onSend = { [weak self] text, color in
            self?.viewModel.sendMessage(text, color: color)
        }

        glassInputBar.inputNode.onVoiceRecordingFinished = { [weak self] fileURL, duration, waveform in
            self?.viewModel.sendVoiceMessage(fileURL: fileURL, duration: duration, waveform: waveform)
        }

        glassInputBar.inputNode.onAttachTapped = { [weak self] in
            self?.presentAttachmentSheet()
        }

        glassInputBar.inputNode.onReplyCancelled = { [weak self] in
            self?.viewModel.setReplyTarget(nil)
            self?.viewModel.clearPendingForward()
        }

        glassInputBar.onScrollButtonLayoutChanged = { [weak self] iconFrame, iconAlpha, tapFrame, tapAlpha in
            guard let self else { return }
            self.scrollButtonIcon.frame = iconFrame
            self.scrollButtonIcon.alpha = iconAlpha
            self.scrollButtonTap.frame = tapFrame
            self.scrollButtonTap.alpha = tapAlpha
        }
    }

    @objc private func scrollToLiveTapped() {
        navigateToLive()
        glassInputBar.scrollButtonVisible = false
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

            // Call events use a standalone centered cell, not a MessageCellNode
            if case .callEvent = message.content {
                return CallEventCellNode(message: message)
            }

            let cellNode: MessageCellNode
            switch message.content {
            case .voice:
                cellNode = VoiceMessageCellNode(message: message, audioPlayer: audioPlayer)
            case .image:
                let imageCell = ImageMessageCellNode(message: message)
                imageCell.onImageTapped = { [weak self, weak imageCell] in
                    guard let self, let imageCell else { return }
                    self.presentImageViewer(for: message, from: imageCell)
                }
                cellNode = imageCell
            case .file:
                let fileCell = FileCellNode(message: message)
                fileCell.onFileTapped = { [weak self] in
                    guard let self else { return }
                    self.handleFileTap(message: message, cellNode: fileCell)
                }
                cellNode = fileCell
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

            cellNode.onReplyHeaderTapped = { [weak self] eventId in
                self?.navigateToMessage(eventId: eventId)
            }

            cellNode.accessibilityActionsProvider = { [weak self] in
                self?.buildAccessibilityActions(for: message) ?? []
            }

            return cellNode
        }
    }

    private func buildAccessibilityActions(for message: ChatMessage) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []

        actions.append(UIAccessibilityCustomAction(name: "Reply") { [weak self] _ in
            self?.viewModel.setReplyTarget(message)
            return true
        })

        if !message.content.isRedacted {
            actions.append(UIAccessibilityCustomAction(name: "Forward") { [weak self] _ in
                self?.onForwardMessage?(message)
                return true
            })
        }

        if message.itemIdentifier != nil && !message.content.isRedacted {
            actions.append(UIAccessibilityCustomAction(name: "Delete") { [weak self] _ in
                self?.triggerPaintSplashDelete(for: message)
                return true
            })
        }

        return actions
    }

    // MARK: - Context Menu

    private func presentContextMenu(for message: ChatMessage, from cellNode: ContextMenuCellNode) {
        guard let window = view.window,
              let info = cellNode.extractBubbleForMenu(in: window.coordinateSpace) else { return }

        var actions = [
            ContextMenuAction(
                title: "Reply",
                image: UIImage(systemName: "arrowshape.turn.up.left"),
                handler: { [weak self] in self?.viewModel.setReplyTarget(message) }
            )
        ]

        if !message.content.isRedacted {
            actions.append(ContextMenuAction(
                title: "Forward",
                image: UIImage(systemName: "arrowshape.turn.up.right"),
                handler: { [weak self] in
                    self?.onForwardMessage?(message)
                }
            ))
        }

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
        !viewModel.isPaginating && !viewModel.sdkPaginationExhausted
    }

    func tableNode(_ tableNode: ASTableNode, willBeginBatchFetchWith context: ASBatchContext) {
        // Texture invokes this hook on a background queue — use it!
        // The GRDB query + merge/sort stays on bg; we only marshal
        // the UI-mutating apply step back to main.
        if let page = viewModel.queryOlderFromDB() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.viewModel.applyOlderPageFromDB(page)
                context.completeBatchFetching(true)
            }
            return
        }

        // No GRDB data available — fall back to SDK pagination.
        // These methods already manage their own threading.
        DispatchQueue.main.async { [weak self] in
            self?.runServerBatchFetch(context: context)
        }
    }

    private func runServerBatchFetch(context: ASBatchContext) {
        let countBefore = viewModel.messages.count
        viewModel.loadOlderFromServer()

        batchFetchCancellable = viewModel.$isPaginating
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // If pagination returned but visible count didn't
                // grow, we've hit the start (or only got filtered
                // events like call signaling). Stop fetching.
                if self.viewModel.messages.count <= countBefore {
                    self.viewModel.sdkPaginationExhausted = true
                }
                context.completeBatchFetching(true)
                self.batchFetchCancellable = nil
            }
    }

    // MARK: - Scroll

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
        guard !isTeleporting else { return }

        // Load newer messages when scrolling toward bottom (inverted: small contentOffset.y)
        if !viewModel.isAtLiveEdge && scrollView.contentOffset.y < 200 {
            viewModel.loadNewerMessages()
        }

        // Show scroll-to-live button when scrolled far from bottom (inverted: large contentOffset.y)
        let scrolledFar = scrollView.contentOffset.y > scrollView.bounds.height * 1.5
        let shouldShow = scrolledFar && viewModel.messages.count > 20
        glassInputBar.scrollButtonVisible = shouldShow
    }

    // MARK: - Smart Navigation (Journey / Teleportation)

    private func navigateToMessage(eventId: String) {
        // If message is visible on screen — smooth scroll (journey)
        if let idx = viewModel.indexOfMessage(eventId: eventId) {
            let targetIP = IndexPath(row: idx, section: 0)
            let visibleRect = node.tableNode.view.bounds
            if let cell = node.tableNode.view.cellForRow(at: targetIP),
               visibleRect.intersects(cell.frame) {
                print("[nav] journey — already visible at idx=\(idx)")
                node.tableNode.scrollToRow(at: targetIP, at: .middle, animated: true)
                highlightMessage(eventId: eventId, delay: 0.3)
                return
            }
        }
        // Otherwise — teleport (Telegram-style snapshot slide)
        // Inverted table: higher row = older. Jumping to older → content slides down, to newer → up.
        let currentFirst = node.tableNode.view.indexPathsForVisibleRows?.first?.row ?? 0
        let targetIdx = viewModel.indexOfMessage(eventId: eventId)
        let direction: TeleportDirection = (targetIdx ?? Int.max) > currentFirst ? .up : .down

        teleport(direction: direction) {
            self.viewModel.jumpToMessage(eventId: eventId)
        } scrollAfter: {
            if let idx = self.viewModel.indexOfMessage(eventId: eventId) {
                self.node.tableNode.scrollToRow(at: IndexPath(row: idx, section: 0), at: .middle, animated: false)
            }
            self.highlightMessage(eventId: eventId, delay: 0.1)
        }
    }

    private func highlightMessage(eventId: String, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let idx = self.viewModel.messages.firstIndex(where: { $0.eventId == eventId }),
                  let cellNode = self.node.tableNode.nodeForRow(at: IndexPath(row: idx, section: 0))
                      as? MessageCellNode
            else { return }
            cellNode.highlightBubble()
        }
    }

    private func navigateToLive() {
        if viewModel.isAtLiveEdge {
            node.tableNode.scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: true)
            return
        }
        // Jumping to live (newest) → content slides up
        teleport(direction: .down) {
            self.viewModel.jumpToLive()
        } scrollAfter: {
            self.node.tableNode.contentOffset = CGPoint(x: 0, y: -self.node.tableNode.contentInset.top)
        }
    }

    /// Snapshot-based teleportation (Telegram approach).
    /// Direction: which way new content arrives FROM (visually).
    /// `.up` = jumping to older messages: snapshot slides down, new content enters from top.
    /// `.down` = jumping to newer messages: snapshot slides up, new content enters from bottom.
    private func teleport(direction: TeleportDirection, swapData: () -> Void, scrollAfter: () -> Void) {
        let tableView = node.tableNode.view
        guard let snapshot = tableView.snapshotView(afterScreenUpdates: false) else {
            swapData()
            return
        }

        isTeleporting = true
        // Inverted table: jump-to-older → content slides DOWN (camera pans up)
        //                  jump-to-newer → content slides UP (camera pans down)
        let sign: CGFloat = direction == .up ? 1 : -1

        let slideHeight = view.bounds.height

        // 1. Overlay snapshot in a container (clips to table bounds)
        let snapshotContainer = UIView(frame: tableView.frame)
        snapshotContainer.clipsToBounds = true
        snapshot.frame = snapshotContainer.bounds
        snapshotContainer.addSubview(snapshot)
        view.insertSubview(snapshotContainer, aboveSubview: tableView)

        // 2. Swap data under snapshot (invisible)
        swapData()
        node.tableNode.reloadData()
        node.tableNode.view.layoutIfNeeded()
        scrollAfter()

        // 3. Animate with spring: snapshot exits one way, new content enters from the other
        let tableLayer = tableView.layer
        let originalPosition = tableLayer.position

        // New content starts offset in the opposite direction from snapshot exit
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tableLayer.position = CGPoint(x: originalPosition.x, y: originalPosition.y - sign * slideHeight)
        CATransaction.commit()

        let springTiming = CASpringAnimation(keyPath: "position.y")
        springTiming.damping = 500
        springTiming.stiffness = 1000
        springTiming.mass = 3
        springTiming.initialVelocity = 0
        springTiming.duration = springTiming.settlingDuration

        // Snapshot exits in `sign` direction
        let snapshotAnim = springTiming.copy() as! CASpringAnimation
        snapshotAnim.fromValue = snapshotContainer.layer.position.y
        snapshotAnim.toValue = snapshotContainer.layer.position.y + sign * slideHeight
        snapshotAnim.isRemovedOnCompletion = false
        snapshotAnim.fillMode = .forwards
        snapshotContainer.layer.add(snapshotAnim, forKey: "teleportOut")

        // Table slides from offset to original position
        let tableAnim = springTiming.copy() as! CASpringAnimation
        tableAnim.fromValue = originalPosition.y - sign * slideHeight
        tableAnim.toValue = originalPosition.y
        tableAnim.isRemovedOnCompletion = false
        tableAnim.fillMode = .forwards
        tableLayer.position = originalPosition
        tableAnim.delegate = TeleportAnimationDelegate { [weak self, weak snapshotContainer] in
            snapshotContainer?.removeFromSuperview()
            self?.isTeleporting = false
        }
        tableLayer.add(tableAnim, forKey: "teleportIn")

        // Sustain glass capture for the full spring animation
        GlassService.shared.captureFor(duration: springTiming.settlingDuration)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartOffsetY = scrollView.contentOffset.y
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView,
                                   withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Deliberate flick only: fast AND far. `velocity` in pt/ms.
        let distance = abs(scrollView.contentOffset.y - dragStartOffsetY)
        if abs(velocity.y) > Self.keyboardDismissVelocity,
           distance > Self.keyboardDismissDistance {
            glassInputBar.inputNode.textInputNode.resignFirstResponder()
        }
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

    // MARK: - Attachment Sheet

    private func presentAttachmentSheet() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: String(localized: "Photos"), style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Files"), style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))

        present(sheet, animated: true)
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

    // MARK: - Document Picker

    private func presentDocumentPicker() {
        isPickerPresented = true
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - File Tap → Download + Quick Look

    private func handleFileTap(message: ChatMessage, cellNode: FileCellNode) {
        guard case .file(let source, let filename, let mimetype, _) = message.content
        else { return }

        // Already cached — show immediately
        if let cachedURL = FileCacheService.shared.cachedURL(for: source) {
            presentQuickLook(url: cachedURL)
            return
        }

        // Download
        cellNode.setDownloadState(.downloading(progress: -1))

        Task {
            do {
                let localURL = try await FileCacheService.shared.downloadFile(
                    source: source,
                    filename: filename,
                    mimetype: mimetype
                ) { [weak cellNode] progress in
                    cellNode?.setDownloadState(.downloading(progress: progress))
                }
                await MainActor.run { [weak cellNode] in
                    cellNode?.setDownloadState(.downloaded)
                    self.presentQuickLook(url: localURL)
                }
            } catch {
                await MainActor.run { [weak cellNode] in
                    cellNode?.setDownloadState(.idle)
                }
            }
        }
    }

    // MARK: - Image Viewer

    private func presentImageViewer(for message: ChatMessage, from cell: ImageMessageCellNode) {
        guard let image = cell.currentImage else { return }

        var source: MediaSource?
        if case .image(let src, _, _, _) = message.content {
            source = src
        }

        let cellImageView = cell.imageNodeView
        let sourceFrame = cellImageView.convert(cellImageView.bounds, to: nil)

        let viewer = ImageViewerController(image: image, mediaSource: source)
        viewer.sourceFrame = sourceFrame

        present(viewer, animated: false) {
            viewer.animateIn(from: sourceFrame)
        }
    }

    // MARK: - Quick Look

    private var quickLookURL: URL?

    private func presentQuickLook(url: URL) {
        quickLookURL = url
        let ql = QLPreviewController()
        ql.dataSource = self
        ql.delegate = self
        present(ql, animated: true)
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

// MARK: - UIDocumentPickerDelegate

extension ChatViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        isPickerPresented = false
        for url in urls.prefix(10) {
            viewModel.sendFile(url: url)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isPickerPresented = false
    }
}

// MARK: - QLPreviewControllerDataSource

extension ChatViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        quickLookURL != nil ? 1 : 0
    }

    func previewController(
        _ controller: QLPreviewController,
        previewItemAt index: Int
    ) -> QLPreviewItem {
        (quickLookURL ?? URL(fileURLWithPath: "")) as NSURL
    }
}

// MARK: - QLPreviewControllerDelegate

extension ChatViewController: QLPreviewControllerDelegate {
    func previewController(
        _ controller: QLPreviewController,
        editingModeFor previewItem: QLPreviewItem
    ) -> QLPreviewItemEditingMode {
        .updateContents
    }

    func previewController(
        _ controller: QLPreviewController,
        didUpdateContentsOf previewItem: QLPreviewItem
    ) {
        // Markup edits saved to the cached file — no action needed.
    }
}

// MARK: - Teleport Direction

private enum TeleportDirection {
    case up    // jumping to older — snapshot exits down, new content enters from top
    case down  // jumping to newer — snapshot exits up, new content enters from bottom
}

// MARK: - UIGestureRecognizerDelegate

extension ChatViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other is UILongPressGestureRecognizer
    }
}

// MARK: - Teleport Animation Delegate

private final class TeleportAnimationDelegate: NSObject, CAAnimationDelegate {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { completion() }
}
