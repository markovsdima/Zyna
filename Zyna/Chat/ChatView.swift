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

    private enum InputBarInsetCompensation {
        static let liveEdgeTolerance: CGFloat = 2
        static let automaticZoneTolerance: CGFloat = 8
    }

    private enum ServerBatchFetchWait {
        static let pollInterval: TimeInterval = 0.1
        static let maxAttempts = 15
    }

    private enum LiveNavigation {
        static let teleportDistanceScreens: CGFloat = 1.5
    }

    private enum ContentUpdates {
        static let liveEdgeTolerance: CGFloat = 24
    }

    private enum ScrollToLiveBadge {
        static let minWidth: CGFloat = 20
        static let height: CGFloat = 20
        static let horizontalPadding: CGFloat = 6
        static let overlapX: CGFloat = 4
        static let overlapY: CGFloat = 4
        static let maxCount = 99
    }

    private enum ReadReceipts {
        static let visibilityThreshold: CGFloat = 0.6
        static let baselineLiveTolerance: CGFloat = 24
        static let scrollDebounce: TimeInterval = 0.15
        static let contentUpdateDelay: TimeInterval = 0.05
    }

    private enum RedactionAnimations {
        static let bootstrapArmDelay: TimeInterval = 0.75
    }

    private struct PendingCompositeGroupDelete {
        let messageIds: Set<String>
        let splashTarget: PaintSplashTrigger.SnapshotTarget?
    }

    private final class PendingIncomingCompositeGroupRedaction {
        let groupId: String
        let allMessageIds: Set<String>
        let totalCount: Int
        let splashTarget: PaintSplashTrigger.SnapshotTarget?
        var redactedMessageIds: Set<String>
        var remainingCountAfter: Int
        var workItem: DispatchWorkItem?

        init(
            groupId: String,
            allMessageIds: Set<String>,
            totalCount: Int,
            redactedMessageIds: Set<String>,
            remainingCountAfter: Int,
            splashTarget: PaintSplashTrigger.SnapshotTarget?
        ) {
            self.groupId = groupId
            self.allMessageIds = allMessageIds
            self.totalCount = totalCount
            self.redactedMessageIds = redactedMessageIds
            self.remainingCountAfter = remainingCountAfter
            self.splashTarget = splashTarget
        }
    }

    var onBack: (() -> Void)?
    var onCallTapped: (() -> Void)?
    var onTitleTapped: ((String) -> Void)?
    var onRoomDetailsTapped: (() -> Void)?
    var onForwardMessage: ((ChatMessage) -> Void)?

    private let viewModel: ChatViewModel
    private let composerController = ChatComposerController()
    private let documentScanFlow = DocumentScanFlow()
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
    private let scrollButtonBadgeBackground = UIView()
    private let scrollButtonBadgeLabel = UILabel()
    private let dateHeaderOverlayManager = DateHeaderOverlayManager()
    
    /// Flip to `true` to show Apple vs Custom glass comparison overlay (iOS 26+)
    private static let showGlassComparison = false
    private enum GlassSourceMode {
        case table
    }
    private static let glassSourceMode: GlassSourceMode = .table

    // TODO: dial in via side-by-side gesture comparison — current values
    // are a reasonable starting point, not a final choice.
    /// Release-velocity threshold (pt/ms) a drag must exceed to dismiss the keyboard.
    private static let keyboardDismissVelocity: CGFloat = 1.0
    /// Minimum scroll distance (pt). Paired with the velocity threshold above.
    private static let keyboardDismissDistance: CGFloat = 80

    private var dragStartOffsetY: CGFloat = 0

    private lazy var glassComparison = GlassComparisonView()
    private lazy var glassTuning = GlassTuningView()
    private var previousInputCoveredHeight: CGFloat?
    private let audioPlayer = AudioPlayerService()
    private var activeContextMenu: ContextMenuController?
    private var pendingRedactionBatches: [ChatViewModel.DetectedRedactionBatch] = []
    private var isTeleporting = false
    private var isPickerPresented = false
    private var interactionLocks = Set<String>()
    private lazy var fpsBooster = ScrollFPSBooster(hostView: node.tableNode.view)
    private var isGroupChat = false
    private weak var photoPreviewController: PhotoGroupPreviewController?
    private weak var filePreviewController: FileAttachmentPreviewController?
    private var shouldPresentAttachmentPreviewAfterDismiss = false
    private var pendingAnimatedDeleteTargets: [String: PaintSplashTrigger.SnapshotTarget] = [:]
    private var pendingCompositeGroupDeletes: [String: PendingCompositeGroupDelete] = [:]
    private var pendingIncomingGroupRedactions: [String: PendingIncomingCompositeGroupRedaction] = [:]
    private var activeContextMenuBubbleFrameInScreen: CGRect?
    private var activeContextMenuItemFramesInScreen: [String: CGRect] = [:]
    private var visibleReadReceiptEvalWork: DispatchWorkItem?
    private var unseenIncomingMessageCount = 0
    private var pendingPostSendPinToLive = false
    private var isEditingInputActive = false
    private var redactionAnimationsArmed = false
    private var redactionAnimationArmWork: DispatchWorkItem?
    private var didCleanupViewModel = false
    private var prefetchedAppearanceUserIds = Set<String>()

    private var isPreviewMode: Bool {
        viewModel.mode.isPreview
    }

    // MARK: - Init

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(node: ChatNode())
        hidesBottomBarWhenPushed = !viewModel.mode.isPreview
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cleanupViewModelIfNeeded()
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
        node.tableNode.automaticallyAdjustsContentOffset = false

        if !isPreviewMode {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tableTapped))
            tap.cancelsTouchesInView = false
            // Cells' ContextSourceNode installs a zero-duration long-press
            // that would otherwise swallow the tap — recognize simultaneously.
            tap.delegate = self
            // Let the scroll pan take precedence: a flick that starts a scroll
            // shouldn't also register as a dismissing tap.
            tap.require(toFail: node.tableNode.view.panGestureRecognizer)
            node.tableNode.view.addGestureRecognizer(tap)
        }

        setupNavigationBar()
        bindViewModel()
        if !isPreviewMode {
            bindInput()
            bindComposer()
        }

        // Glass nav bar (replaces system nav bar)
        if !isPreviewMode {
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
        }

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
        if !isPreviewMode {
            view.addSubview(searchBar)
        }

        // Invite banner (hidden by default)
        inviteBanner.isHidden = !viewModel.isInvited
        inviteBanner.onAccept = { [weak self] in
            self?.viewModel.acceptInvite()
        }
        if !isPreviewMode {
            view.addSubview(inviteBanner)
        }

        // Glass input bar
        if !isPreviewMode {
            glassInputBar.isHidden = viewModel.isInvited
            node.addSubnode(glassInputBar)
            node.glassInputBar = glassInputBar
        }

        // Scroll-to-live button — lives on node.view so its tap target
        // works when positioned above the input bar's bounds.
        scrollButtonIcon.image = AppIcon.chevronDown.template(size: 24)
        scrollButtonIcon.tintColor = GlassAdaptiveMaterial.light.glyphForeground
        scrollButtonIcon.contentMode = .center
        scrollButtonIcon.alpha = 0
        scrollButtonIcon.isUserInteractionEnabled = false
        if !isPreviewMode {
            node.view.addSubview(scrollButtonIcon)
        }

        scrollButtonTap.alpha = 0
        scrollButtonTap.accessibilityLabel = "Scroll to bottom"
        scrollButtonTap.accessibilityTraits = .button
        scrollButtonTap.addTarget(self, action: #selector(scrollToLiveTapped), for: .touchUpInside)
        if !isPreviewMode {
            node.view.addSubview(scrollButtonTap)
            node.scrollButtonTap = scrollButtonTap
        }

        scrollButtonBadgeBackground.backgroundColor = .systemRed
        scrollButtonBadgeBackground.alpha = 0
        scrollButtonBadgeBackground.isUserInteractionEnabled = false
        if !isPreviewMode {
            node.view.addSubview(scrollButtonBadgeBackground)
        }

        scrollButtonBadgeLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        scrollButtonBadgeLabel.textColor = .white
        scrollButtonBadgeLabel.textAlignment = .center
        scrollButtonBadgeLabel.alpha = 0
        scrollButtonBadgeLabel.isUserInteractionEnabled = false
        if !isPreviewMode {
            node.view.addSubview(scrollButtonBadgeLabel)
        }

        if !isPreviewMode {
            refreshGlassSourceBinding()
        }

        if !isPreviewMode {
            node.view.addSubview(dateHeaderOverlayManager.containerView)
        }

        if Self.showGlassComparison && !isPreviewMode {
            view.addSubview(glassComparison)
            view.addSubview(glassTuning)
        }


        // Pre-set inset
        if isPreviewMode {
            let inset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            node.tableNode.contentInset = inset
            node.tableNode.view.verticalScrollIndicatorInsets = inset
        } else {
            let estimatedBarHeight: CGFloat = 49 + DeviceInsets.bottom
            node.tableNode.contentInset.top = estimatedBarHeight
            node.tableNode.view.verticalScrollIndicatorInsets.top = estimatedBarHeight
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if isPreviewMode {
            let inset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            node.tableNode.contentInset = inset
            node.tableNode.view.verticalScrollIndicatorInsets = inset
            return
        }

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
        updateTableInsetsForInputBar()
        updateDateHeaderOverlay()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isPreviewMode else { return }
        // Pre-warm glass before the navigation transition starts so the
        // shared render loop is already active on the first animated frame.
        GlassService.shared.captureFor(duration: 0.5)
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isPreviewMode else { return }
        // Force glass recapture after navigation push completes
        GlassService.shared.setNeedsCapture()
        if shouldPresentAttachmentPreviewAfterDismiss {
            presentComposerPreviewIfNeeded()
        }
        scheduleRedactionAnimationArming()
        scheduleVisibleReadReceiptEvaluation(delay: ReadReceipts.contentUpdateDelay)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visibleReadReceiptEvalWork?.cancel()
        redactionAnimationArmWork?.cancel()

        let shouldCleanup = isPreviewMode
            || isMovingFromParent
            || isBeingDismissed
            || navigationController?.isBeingDismissed == true
            || parent?.isBeingDismissed == true

        if shouldCleanup {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            cleanupViewModelIfNeeded()
        }
    }

    private func cleanupViewModelIfNeeded() {
        guard !didCleanupViewModel else { return }
        didCleanupViewModel = true
        audioPlayer.stop()
        viewModel.cleanup()
    }

    // MARK: - Navigation

    /// Keep the current viewport stable when the input bar/keyboard
    /// changes how much space is covered at the bottom. The table is
    /// inverted, so that covered height lives in `contentInset.top`.
    private func updateTableInsetsForInputBar() {
        guard !isPreviewMode else {
            let inset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            node.tableNode.contentInset = inset
            node.tableNode.view.verticalScrollIndicatorInsets = inset
            return
        }

        let newCoveredHeight = glassInputBar.coveredHeight
        let previousCoveredHeight = previousInputCoveredHeight
        let tableView = node.tableNode.view
        let liveEdgeDistance = tableDistanceToLiveEdge()
        let wasPinnedToLiveEdge = liveEdgeDistance <= InputBarInsetCompensation.liveEdgeTolerance

        node.tableNode.contentInset.top = newCoveredHeight
        tableView.verticalScrollIndicatorInsets.top = newCoveredHeight

        // Don't fight UIKit's rubber-band or active user scroll. Snapping the
        // inverted table back to the live edge during an elastic pull is what
        // kills the springiness and makes the edge stutter.
        if shouldDeferTableOffsetCompensation(for: tableView) {
            previousInputCoveredHeight = newCoveredHeight
            return
        }

        if let previousCoveredHeight {
            let compensationDelta = newCoveredHeight - previousCoveredHeight
            let isInAutomaticZone = liveEdgeDistance
                <= abs(compensationDelta) + InputBarInsetCompensation.automaticZoneTolerance
            if wasPinnedToLiveEdge {
                pinTableToLiveEdge()
            } else if isInAutomaticZone && compensationDelta < 0 {
                // Near the live edge, shrinking the covered area already pulls the
                // table back down through UIKit's own layout/clamping. Applying our
                // full manual delta on top causes the overshoot.
            } else {
                compensateTableOffsetForInputHeightChange(
                    from: previousCoveredHeight,
                    to: newCoveredHeight
                )
            }
        }

        previousInputCoveredHeight = newCoveredHeight
    }

    private func tableOffsetBounds(for tableView: UIScrollView) -> (minY: CGFloat, maxY: CGFloat) {
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
            minY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )
        return (minY, maxY)
    }

    private func isTableRubberBanding(_ tableView: UIScrollView, tolerance: CGFloat = 0.5) -> Bool {
        let bounds = tableOffsetBounds(for: tableView)
        return tableView.contentOffset.y < bounds.minY - tolerance
            || tableView.contentOffset.y > bounds.maxY + tolerance
    }

    private func shouldDeferTableOffsetCompensation(for tableView: UIScrollView) -> Bool {
        if tableView.isTracking || tableView.isDragging || tableView.isDecelerating {
            return true
        }
        return isTableRubberBanding(tableView)
    }

    private func tableDistanceToLiveEdge() -> CGFloat {
        let tableView = node.tableNode.view
        let liveOffsetY = tableOffsetBounds(for: tableView).minY
        return max(0, node.tableNode.contentOffset.y - liveOffsetY)
    }

    private func shouldTeleportToLive() -> Bool {
        let tableView = node.tableNode.view
        let threshold = tableView.bounds.height * LiveNavigation.teleportDistanceScreens
        return tableDistanceToLiveEdge() > threshold
    }

    private func isViewportPinnedToLiveEdge(
        tolerance: CGFloat = ContentUpdates.liveEdgeTolerance
    ) -> Bool {
        let tableView = node.tableNode.view
        guard viewModel.isAtLiveEdge else { return false }
        guard !isTableRubberBanding(tableView) else { return false }
        return tableDistanceToLiveEdge() <= tolerance
    }

    private func scheduleVisibleReadReceiptEvaluation(delay: TimeInterval = ReadReceipts.scrollDebounce) {
        guard !isPreviewMode else { return }
        visibleReadReceiptEvalWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateVisibleReadReceiptCandidate()
        }
        visibleReadReceiptEvalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateVisibleReadReceiptCandidate() {
        guard !isPreviewMode, !isTeleporting else { return }

        node.tableNode.view.layoutIfNeeded()
        let candidate = currentVisibleReadReceiptCandidate()
        let canEstablishBaseline = viewModel.isAtLiveEdge
            && tableDistanceToLiveEdge() <= ReadReceipts.baselineLiveTolerance

        viewModel.updateVisibleReadReceiptCandidate(
            eventId: candidate,
            canEstablishBaseline: canEstablishBaseline
        )
    }

    private func currentVisibleReadReceiptCandidate() -> String? {
        let visibleRows = node.tableNode.indexPathsForVisibleRows()
        guard let viewport = unobscuredTableViewportInView(),
              !visibleRows.isEmpty
        else {
            return nil
        }

        let tableView = node.tableNode.view
        let rows = viewModel.rows

        for indexPath in visibleRows.sorted(by: { $0.row < $1.row }) {
            guard rows.indices.contains(indexPath.row),
                  let message = rows[indexPath.row].message
            else { continue }

            guard let eventId = message.eventId else { continue }

            let rowRect = tableView.convert(tableView.rectForRow(at: indexPath), to: view)
            guard rowRect.width > 0, rowRect.height > 0 else { continue }

            let visibleRect = rowRect.intersection(viewport)
            guard !visibleRect.isNull, visibleRect.width > 0, visibleRect.height > 0 else { continue }

            let maxRelevantVisibleHeight = min(rowRect.height, viewport.height)
            guard maxRelevantVisibleHeight > 0 else { continue }

            if visibleRect.height / maxRelevantVisibleHeight >= ReadReceipts.visibilityThreshold {
                return eventId
            }
        }

        return nil
    }

    private func unobscuredTableViewportInView() -> CGRect? {
        let tableView = node.tableNode.view
        let tableFrame = tableView.convert(tableView.bounds, to: view)

        let topObstruction = max(
            tableFrame.minY,
            glassNavBar.frame.maxY,
            searchBar.isHidden ? tableFrame.minY : searchBar.frame.maxY,
            inviteBanner.isHidden ? tableFrame.minY : inviteBanner.frame.maxY
        )
        let bottomObstruction = min(
            tableFrame.maxY,
            glassInputBar.isHidden ? view.bounds.maxY : glassInputBar.frame.minY
        )

        guard bottomObstruction > topObstruction else { return nil }

        return CGRect(
            x: tableFrame.minX,
            y: topObstruction,
            width: tableFrame.width,
            height: bottomObstruction - topObstruction
        )
    }

    private func updateDateHeaderOverlay(animated: Bool = false) {
        guard !isPreviewMode,
              !isTeleporting,
              let viewport = unobscuredTableViewportInView(),
              !viewModel.rows.isEmpty
        else {
            dateHeaderOverlayManager.hide(animated: animated)
            return
        }

        let tableView = node.tableNode.view
        let isScrolling = tableView.isTracking || tableView.isDragging || tableView.isDecelerating
        dateHeaderOverlayManager.update(
            viewport: viewport,
            rows: viewModel.rows,
            visibleIndexPaths: node.tableNode.indexPathsForVisibleRows(),
            tableView: tableView,
            hostView: view,
            isScrolling: isScrolling,
            animated: animated || !isScrolling
        )
        node.view.bringSubviewToFront(dateHeaderOverlayManager.containerView)
    }

    private func pinTableToLiveEdge() {
        let tableView = node.tableNode.view
        let liveOffsetY = tableOffsetBounds(for: tableView).minY
        var targetOffset = node.tableNode.contentOffset
        targetOffset.y = liveOffsetY
        node.tableNode.contentOffset = targetOffset
    }

    private func scrollButtonBadgeText() -> String? {
        guard unseenIncomingMessageCount > 0 else { return nil }
        if unseenIncomingMessageCount > ScrollToLiveBadge.maxCount {
            return "\(ScrollToLiveBadge.maxCount)+"
        }
        return "\(unseenIncomingMessageCount)"
    }

    private func updateScrollButtonAccessibilityLabel() {
        if unseenIncomingMessageCount > 0 {
            scrollButtonTap.accessibilityLabel = "Scroll to latest messages, \(unseenIncomingMessageCount) unread"
        } else {
            scrollButtonTap.accessibilityLabel = "Scroll to bottom"
        }
    }

    private func updateScrollButtonBadgeLayout(
        relativeTo iconFrame: CGRect,
        iconAlpha: CGFloat,
        tapAlpha: CGFloat
    ) {
        guard let badgeText = scrollButtonBadgeText(),
              !iconFrame.isEmpty
        else {
            scrollButtonBadgeBackground.alpha = 0
            scrollButtonBadgeLabel.alpha = 0
            return
        }

        let textSize = badgeText.size(withAttributes: [
            .font: scrollButtonBadgeLabel.font as Any
        ])
        let badgeWidth = max(
            ScrollToLiveBadge.minWidth,
            ceil(textSize.width) + ScrollToLiveBadge.horizontalPadding * 2
        )
        let badgeFrame = CGRect(
            x: iconFrame.maxX - ScrollToLiveBadge.overlapX,
            y: iconFrame.minY - ScrollToLiveBadge.overlapY,
            width: badgeWidth,
            height: ScrollToLiveBadge.height
        )

        scrollButtonBadgeLabel.text = badgeText
        scrollButtonBadgeBackground.frame = badgeFrame
        scrollButtonBadgeBackground.layer.cornerRadius = ScrollToLiveBadge.height / 2
        scrollButtonBadgeLabel.frame = badgeFrame

        let alpha = min(iconAlpha, tapAlpha)
        scrollButtonBadgeBackground.alpha = alpha
        scrollButtonBadgeLabel.alpha = alpha
    }

    private func resetUnseenIncomingMessages() {
        guard !isPreviewMode else { return }
        guard unseenIncomingMessageCount != 0 else { return }
        unseenIncomingMessageCount = 0
        updateScrollButtonAccessibilityLabel()
        updateScrollButtonBadgeLayout(
            relativeTo: scrollButtonIcon.frame,
            iconAlpha: scrollButtonIcon.alpha,
            tapAlpha: scrollButtonTap.alpha
        )
    }

    private func noteUnseenIncomingMessagesIfNeeded(
        insertions: [IndexPath],
        minimumVisibleRowBeforeUpdate: Int?
    ) {
        guard !isPreviewMode else { return }
        guard let minimumVisibleRowBeforeUpdate else { return }

        var newUnseenIncoming = 0
        for indexPath in insertions where indexPath.row < minimumVisibleRowBeforeUpdate {
            guard viewModel.rows.indices.contains(indexPath.row),
                  let message = viewModel.rows[indexPath.row].message
            else { continue }
            guard !message.isOutgoing, !message.content.isRedacted else { continue }
            newUnseenIncoming += 1
        }

        guard newUnseenIncoming > 0 else { return }
        unseenIncomingMessageCount += newUnseenIncoming
        updateScrollButtonAccessibilityLabel()
    }

    private func updateScrollToLiveVisibility() {
        guard !isPreviewMode else { return }
        if isViewportPinnedToLiveEdge() {
            resetUnseenIncomingMessages()
        }

        let scrolledFar = shouldTeleportToLive()
        let shouldShow = unseenIncomingMessageCount > 0
            || (scrolledFar && viewModel.messages.count > 20)
        glassInputBar.scrollButtonVisible = shouldShow
        updateScrollButtonBadgeLayout(
            relativeTo: scrollButtonIcon.frame,
            iconAlpha: scrollButtonIcon.alpha,
            tapAlpha: scrollButtonTap.alpha
        )
    }

    private func compensateTableOffsetForInputHeightChange(from oldHeight: CGFloat, to newHeight: CGFloat) {
        let delta = newHeight - oldHeight
        guard abs(delta) > 0.5 else { return }

        let tableNode = node.tableNode
        let tableView = node.tableNode.view
        let bounds = tableOffsetBounds(for: tableView)
        let minOffsetY = bounds.minY
        let maxOffsetY = bounds.maxY

        var targetOffset = tableNode.contentOffset
        targetOffset.y -= delta
        targetOffset.y = min(max(targetOffset.y, minOffsetY), maxOffsetY)
        tableNode.contentOffset = targetOffset
    }

    private func armPostSendPinToLive() {
        pendingPostSendPinToLive = true
        resetUnseenIncomingMessages()
        glassInputBar.scrollButtonVisible = false
    }

    private func finishPostSendPinToLive() {
        guard pendingPostSendPinToLive else { return }
        pinTableToLiveEdge()
        pendingPostSendPinToLive = false
    }

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

        viewModel.$isGroupChat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] flag in
                guard let self, self.isGroupChat != flag else { return }
                self.isGroupChat = flag
                // RoomInfo resolves shortly after appear; one reload
                // makes sender names appear on already-rendered rows.
                self.node.tableNode.reloadData()
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
        guard !isPreviewMode else { return }
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

        ProfileAppearanceService.shared.appearanceDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userId in
                self?.reloadRowsForAppearanceChange(userId: userId)
            }
            .store(in: &cancellables)

        viewModel.onInPlaceUpdate = { [weak self] indexPath, message in
            guard let self,
                  let cellNode = self.node.tableNode.nodeForRow(at: indexPath) as? MessageCellNode
            else { return }
            self.configureMessageDrivenInteractions(for: cellNode, message: message)
            if let groupCell = cellNode as? PhotoGroupMessageCellNode {
                groupCell.updateMediaGroupPresentation(message.mediaGroupPresentation)
            }
            cellNode.updateAccessibilityMessage(message)
            cellNode.updateSendStatus(message.effectiveSendStatus)
            cellNode.updateClusterMembership(isLastInCluster: message.isLastInCluster)
            cellNode.updateReactions(message.reactions)
            cellNode.refreshAccessibilityForwarding()
        }

        viewModel.onRedactedDetected = { [weak self] batch in
            self?.handleRedactionBatch(batch)
        }

        viewModel.onRedactionFailed = { [weak self] messageId, _, disposition in
            self?.handleRedactionFailure(for: messageId, disposition: disposition)
        }

        viewModel.canRestoreFailedEditDraft = { [weak self] in
            guard let self else { return false }
            return self.glassInputBar.inputNode.currentText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }

        viewModel.$isInvited
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invited in
                guard let self, !self.isPreviewMode else { return }
                self.inviteBanner.isHidden = !invited
                self.glassInputBar.isHidden = invited
            }
            .store(in: &cancellables)

        viewModel.$replyingTo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self, !self.isPreviewMode else { return }
                self.glassInputBar.inputNode.setReplyPreview(
                    senderName: message?.senderDisplayName ?? message?.senderId,
                    body: message?.content.textPreview
                )
            }
            .store(in: &cancellables)

        viewModel.$editingMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self, !self.isPreviewMode else { return }
                let wasEditing = self.isEditingInputActive
                self.isEditingInputActive = message != nil
                self.glassInputBar.inputNode.setEditPreview(
                    body: message?.content.textPreview
                )
                guard let message,
                      let body = self.viewModel.editingInputText(for: message) else {
                    if wasEditing {
                        self.glassInputBar.inputNode.setCurrentText("")
                    }
                    return
                }
                self.glassInputBar.inputNode.setCurrentText(body)
                self.glassInputBar.inputNode.focusTextInput()
            }
            .store(in: &cancellables)

        viewModel.$pendingForwardContent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] forward in
                guard let self, !self.isPreviewMode else { return }
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

    private func reloadRowsForAppearanceChange(userId: String) {
        guard isGroupChat else { return }
        let indexPaths = node.tableNode.indexPathsForVisibleRows().compactMap { indexPath -> IndexPath? in
            guard viewModel.rows.indices.contains(indexPath.row) else { return nil }
            let row = viewModel.rows[indexPath.row]
            guard let message = row.message,
                  !message.isOutgoing,
                  message.senderId == userId else {
                return nil
            }
            return indexPath
        }
        guard !indexPaths.isEmpty else { return }
        node.tableNode.reloadRows(at: indexPaths, with: .none)
    }

    private func applyTableUpdate(_ update: TableUpdate) {
        if isTeleporting {
            // During teleportation: silent reload, no animations
            node.tableNode.reloadData()
            updateDateHeaderOverlay()
            return
        }

        switch update {
        case .reload:
            node.tableNode.reloadData()
            finishPostSendPinToLive()
            updateScrollToLiveVisibility()
            updateDateHeaderOverlay()
            scheduleVisibleReadReceiptEvaluation(delay: ReadReceipts.contentUpdateDelay)
        case .batch(let deletions, let insertions, let moves, let updates, let animated):
            if deletions.isEmpty && insertions.isEmpty && moves.isEmpty && updates.isEmpty { return }
            let minimumVisibleRowBeforeUpdate = node.tableNode.indexPathsForVisibleRows().map(\.row).min()
            let wasPinnedToLiveEdge = isViewportPinnedToLiveEdge()
            let shouldForcePostSendPin = pendingPostSendPinToLive
            let shouldPreserveViewport = !wasPinnedToLiveEdge && !shouldForcePostSendPin
            node.tableNode.automaticallyAdjustsContentOffset = shouldPreserveViewport

            let effectiveAnimated = animated && !shouldPreserveViewport
            let rowAnimation: UITableView.RowAnimation = effectiveAnimated ? .automatic : .none
            node.tableNode.performBatch(animated: effectiveAnimated, updates: {
                if !deletions.isEmpty { node.tableNode.deleteRows(at: deletions, with: rowAnimation) }
                if !insertions.isEmpty { node.tableNode.insertRows(at: insertions, with: rowAnimation) }
                for move in moves {
                    node.tableNode.moveRow(at: move.from, to: move.to)
                }
                if !updates.isEmpty { node.tableNode.reloadRows(at: updates, with: .none) }
            }, completion: { [weak self] _ in
                if shouldPreserveViewport {
                    self?.noteUnseenIncomingMessagesIfNeeded(
                        insertions: insertions,
                        minimumVisibleRowBeforeUpdate: minimumVisibleRowBeforeUpdate
                    )
                }
                if shouldForcePostSendPin {
                    self?.finishPostSendPinToLive()
                } else if wasPinnedToLiveEdge {
                    self?.pinTableToLiveEdge()
                }
                self?.updateScrollToLiveVisibility()
                self?.updateDateHeaderOverlay()
                self?.scheduleVisibleReadReceiptEvaluation(delay: ReadReceipts.contentUpdateDelay)
            })
        }
    }

    private func bindInput() {
        guard !isPreviewMode else { return }

        glassInputBar.inputNode.onSend = { [weak self] text, color in
            guard let self else { return }
            let wasEditing = self.viewModel.editingMessage != nil
            if !wasEditing {
                self.armPostSendPinToLive()
            }
            self.viewModel.sendMessage(text, color: color)
            if !wasEditing {
                self.scrollToLiveAfterUserSend()
            }
        }

        glassInputBar.inputNode.onVoiceRecordingFinished = { [weak self] fileURL, duration, waveform in
            guard let self else { return }
            self.armPostSendPinToLive()
            self.viewModel.sendVoiceMessage(fileURL: fileURL, duration: duration, waveform: waveform)
            self.scrollToLiveAfterUserSend()
        }

        glassInputBar.inputNode.onAttachTapped = { [weak self] in
            guard let self, self.viewModel.editingMessage == nil else { return }
            self.presentAttachmentSheet()
        }

        glassInputBar.inputNode.onReplyCancelled = { [weak self] in
            self?.viewModel.setReplyTarget(nil)
            self?.viewModel.clearPendingForward()
        }

        glassInputBar.inputNode.onEditCancelled = { [weak self] in
            guard let self else { return }
            self.viewModel.setEditingTarget(nil)
            self.glassInputBar.inputNode.setCurrentText("")
        }

        glassInputBar.inputNode.onPastedImages = { [weak self] images in
            guard let self, self.viewModel.editingMessage == nil else { return }
            self.enqueuePastedImages(images)
        }

        glassInputBar.onScrollButtonLayoutChanged = { [weak self] iconFrame, iconAlpha, tapFrame, tapAlpha in
            guard let self else { return }
            self.scrollButtonIcon.frame = iconFrame
            self.scrollButtonIcon.alpha = iconAlpha
            self.scrollButtonTap.frame = tapFrame
            self.scrollButtonTap.alpha = tapAlpha
            self.updateScrollButtonBadgeLayout(
                relativeTo: iconFrame,
                iconAlpha: iconAlpha,
                tapAlpha: tapAlpha
            )
        }

        glassInputBar.onAdaptiveMaterialChanged = { [weak self] material in
            self?.scrollButtonIcon.tintColor = material.glyphForeground
        }
    }

    @objc private func scrollToLiveTapped() {
        resetUnseenIncomingMessages()
        navigateToLive()
        glassInputBar.scrollButtonVisible = false
    }

    private func bindComposer() {
        composerController.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentComposerPreviewIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func scrollToLiveAfterUserSend() {
        navigateToLive()
    }

    @objc private func tableTapped() {
        guard !isPreviewMode else { return }
        glassInputBar.inputNode.textInputNode.resignFirstResponder()
    }

    // MARK: - ASTableDataSource

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        viewModel.rows.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let rows = viewModel.rows
        guard indexPath.row < rows.count else {
            return { ASCellNode() }
        }
        let row = rows[indexPath.row]
        if case .dateDivider(let model) = row {
            return { DateDividerCellNode(model: model) }
        }
        guard case .message(let message) = row else {
            return { ASCellNode() }
        }
        let audioPlayer = self.audioPlayer
        let isGroup = self.isGroupChat
        let isPreview = self.isPreviewMode
        let renderedMessage: ChatMessage
        if isGroup, !message.isOutgoing {
            prefetchAppearanceIfNeeded(userId: message.senderId)
            renderedMessage = message.applyingProfileAppearance(
                ProfileAppearanceService.shared.cachedAppearance(userId: message.senderId)
            )
        } else {
            renderedMessage = message
        }

        // Ask ChatNode for the source view here on the main thread.
        // Texture may build the cell inside the returned block on a background thread,
        // and that block should use the already-resolved view instead of touching
        // `self.node` / the live node hierarchy again.
        let gradientSource = self.node.bubbleGradientSource(for: renderedMessage)
        return { [weak self] in

            // Call events use a standalone centered cell, not a MessageCellNode
            if case .callEvent = renderedMessage.content {
                return CallEventCellNode(message: renderedMessage)
            }
            if case .systemEvent = renderedMessage.content {
                return StateEventCellNode(message: renderedMessage)
            }

            if renderedMessage.mediaGroupPresentation?.hidesStandaloneBubble == true {
                return HiddenMessagePlaceholderCellNode()
            }

            if renderedMessage.mediaGroupPresentation?.rendersCompositeBubble == true {
                let groupCell = PhotoGroupMessageCellNode(message: renderedMessage, isGroupChat: isGroup)
                if !isPreview {
                    groupCell.onPhotoTapped = { [weak self, weak groupCell] index in
                        guard let self, let groupCell else { return }
                        self.presentImageViewer(for: groupCell, itemIndex: index)
                    }
                }
                let cellNode = groupCell
                cellNode.bubbleGradientSource = gradientSource

                if !isPreview {
                    cellNode.onSenderTapped = { [weak self] userId in
                        self?.onTitleTapped?(userId)
                    }

                    cellNode.onInteractionLockChanged = { [weak self] locked in
                        if locked {
                            self?.lockInteraction("contextMenu")
                        } else {
                            self?.unlockInteraction("contextMenu")
                        }
                    }
                }

                self?.configureMessageDrivenInteractions(for: cellNode, message: message)
                return cellNode
            }

            let cellNode: MessageCellNode
            switch renderedMessage.content {
            case .voice:
                cellNode = VoiceMessageCellNode(message: renderedMessage, audioPlayer: audioPlayer, isGroupChat: isGroup)
            case .image:
                let imageCell = ImageMessageCellNode(message: renderedMessage, isGroupChat: isGroup)
                if !isPreview {
                    imageCell.onImageTapped = { [weak self, weak imageCell] in
                        guard let self, let imageCell else { return }
                        self.presentImageViewer(for: message, from: imageCell)
                    }
                }
                cellNode = imageCell
            case .file:
                let fileCell = FileCellNode(message: renderedMessage, isGroupChat: isGroup)
                if !isPreview {
                    fileCell.onFileTapped = { [weak self] in
                        guard let self else { return }
                        self.handleFileTap(message: message, cellNode: fileCell)
                    }
                }
                cellNode = fileCell
            case .systemEvent:
                cellNode = TextMessageCellNode(message: renderedMessage, isGroupChat: isGroup)
            default:
                cellNode = TextMessageCellNode(message: renderedMessage, isGroupChat: isGroup)
            }

            cellNode.bubbleGradientSource = gradientSource

            if !isPreview {
                cellNode.onSenderTapped = { [weak self] userId in
                    self?.onTitleTapped?(userId)
                }

                cellNode.onInteractionLockChanged = { [weak self] locked in
                    if locked {
                        self?.lockInteraction("contextMenu")
                    } else {
                        self?.unlockInteraction("contextMenu")
                    }
                }
            }

            self?.configureMessageDrivenInteractions(for: cellNode, message: message)

            if !isPreview {
                cellNode.onReplyHeaderTapped = { [weak self] eventId in
                    self?.navigateToMessage(eventId: eventId)
                }
            }

            return cellNode
        }
    }

    private func prefetchAppearanceIfNeeded(userId: String) {
        guard prefetchedAppearanceUserIds.insert(userId).inserted else { return }
        ProfileAppearanceService.shared.prefetchAppearance(userId: userId)
    }

    private func configureMessageDrivenInteractions(for cellNode: MessageCellNode, message: ChatMessage) {
        guard !isPreviewMode else {
            configurePreviewInteractions(for: cellNode)
            return
        }

        if message.isSyntheticIncomingAssembly {
            cellNode.onContextMenuActivated = nil
            cellNode.accessibilityActionsProvider = { [] }
        } else {
            cellNode.onContextMenuActivated = { [weak self, weak cellNode] point in
                guard let self, let cellNode else { return }
                self.presentContextMenu(for: message, from: cellNode, activationPoint: point)
            }
            cellNode.accessibilityActionsProvider = { [weak self] in
                self?.buildAccessibilityActions(for: message) ?? []
            }
        }
        cellNode.onReactionTapped = { [weak self] key in
            self?.viewModel.toggleReaction(key, for: message)
        }
    }

    private func configurePreviewInteractions(for cellNode: MessageCellNode) {
        cellNode.allowsInteractiveActions = false
        cellNode.contextSourceNode.isGestureEnabled = false
        cellNode.contextSourceNode.onQuickTap = nil
        cellNode.onContextMenuActivated = nil
        cellNode.onDragChanged = nil
        cellNode.onDragEnded = nil
        cellNode.onInteractionLockChanged = nil
        cellNode.onReactionTapped = nil
        cellNode.onSenderTapped = nil
        cellNode.onReplyHeaderTapped = nil
        cellNode.accessibilityActionsProvider = { [] }

        (cellNode as? PhotoGroupMessageCellNode)?.onPhotoTapped = nil
        (cellNode as? ImageMessageCellNode)?.onImageTapped = nil
        (cellNode as? FileCellNode)?.onFileTapped = nil

        if Thread.isMainThread {
            cellNode.refreshAccessibilityForwarding()
        }
    }

    private func buildAccessibilityActions(for message: ChatMessage) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        let suppressSyntheticActions = message.isSyntheticOutgoingEnvelope || message.isSyntheticIncomingAssembly

        if !suppressSyntheticActions {
            actions.append(UIAccessibilityCustomAction(name: "Reply") { [weak self] _ in
                self?.viewModel.setReplyTarget(message)
                return true
            })
        }

        if let copyable = copyableText(for: message) {
            actions.append(UIAccessibilityCustomAction(name: copyable.actionTitle) { [weak self] _ in
                self?.copyMessageText(message)
                return true
            })
        }

        if message.isTextEditable {
            actions.append(UIAccessibilityCustomAction(name: "Edit") { [weak self] _ in
                self?.viewModel.setEditingTarget(message)
                return true
            })
        }

        if message.itemIdentifier != nil {
            actions.append(UIAccessibilityCustomAction(name: "Add Reaction") { [weak self] _ in
                self?.presentAccessibilityReactionPicker(for: message)
                return true
            })
        }

        if message.reactions.contains(where: \.hasDetailedSenders) {
            actions.append(UIAccessibilityCustomAction(name: "Show Reactions") { [weak self] _ in
                self?.presentAccessibilityReactionSummary(for: message)
                return true
            })
        }

        if !message.content.isRedacted && !suppressSyntheticActions {
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

    private func initialReactionSummaryEntries(for message: ChatMessage) -> [ReactionSummaryEntry] {
        let currentUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        return message.reactions
            .flatMap { reaction in
                reaction.senders.map {
                    ReactionSummaryEntry(
                        id: "\(reaction.key)|\($0.userId)|\($0.timestamp)",
                        userId: $0.userId,
                        displayName: $0.userId,
                        timestamp: Date(timeIntervalSince1970: $0.timestamp),
                        reactionKey: reaction.key,
                        isOwn: $0.userId == currentUserId
                    )
                }
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func presentAccessibilityReactionPicker(for message: ChatMessage) {
        let alert = UIAlertController(
            title: "Add Reaction",
            message: nil,
            preferredStyle: .alert
        )

        for emoji in ContextMenuController.quickEmojis {
            alert.addAction(UIAlertAction(title: emoji, style: .default) { [weak self] _ in
                self?.viewModel.toggleReaction(emoji, for: message)
            })
        }

        alert.addAction(UIAlertAction(title: String(localized: "More Emoji"), style: .default) { [weak self] _ in
            self?.presentAccessibilityFullEmojiPicker(for: message)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentAccessibilityFullEmojiPicker(for message: ChatMessage) {
        let picker = AccessibilityEmojiCategoryPickerViewController { [weak self] emoji in
            self?.viewModel.toggleReaction(emoji, for: message)
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func presentAccessibilityReactionSummary(for message: ChatMessage) {
        let initialEntries = initialReactionSummaryEntries(for: message)
        let summary = AccessibilityReactionSummaryViewController(entries: initialEntries) { [weak self] entry in
            self?.viewModel.toggleReaction(entry.reactionKey, for: message)
        }
        let nav = UINavigationController(rootViewController: summary)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)

        Task { [weak self, weak summary] in
            guard let self else { return }
            let resolved = await self.viewModel.reactionSummaryEntries(for: message)
            await MainActor.run {
                summary?.update(entries: resolved)
            }
        }
    }

    // MARK: - Context Menu

    private func presentContextMenu(
        for message: ChatMessage,
        from cellNode: ContextMenuCellNode,
        activationPoint: CGPoint
    ) {
        guard let window = view.window,
              let info = cellNode.extractBubbleForMenu(in: window.coordinateSpace) else { return }

        activeContextMenuBubbleFrameInScreen = window.convert(
            info.frame,
            to: window.screen.coordinateSpace
        )
        activeContextMenuItemFramesInScreen = [:]
        if let groupCell = cellNode as? PhotoGroupMessageCellNode,
           let presentation = message.mediaGroupPresentation,
           presentation.rendersCompositeBubble {
            activeContextMenuItemFramesInScreen = Dictionary(
                presentation.items.enumerated().compactMap { index, item in
                    guard let frame = groupCell.imageFrameInScreen(at: index) else { return nil }
                    return (item.messageId, frame)
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let isPendingOutgoingMessage = message.isSyntheticOutgoingEnvelope

        var actions: [ContextMenuAction] = []
        if !isPendingOutgoingMessage {
            actions.append(ContextMenuAction(
                title: "Reply",
                image: UIImage(systemName: "arrowshape.turn.up.left"),
                handler: { [weak self] in self?.viewModel.setReplyTarget(message) }
            ))
        }

        if let copyable = copyableText(for: message) {
            actions.append(ContextMenuAction(
                title: copyable.actionTitle,
                image: UIImage(systemName: "doc.on.doc"),
                handler: { [weak self] in self?.copyMessageText(message) }
            ))
        }

        if message.reactions.contains(where: \.hasDetailedSenders) {
            actions.append(ContextMenuAction(
                title: "Reactions",
                image: UIImage(systemName: "list.bullet"),
                behavior: .handleInMenu,
                handler: { [weak self] in
                    guard let self,
                          let menu = self.activeContextMenu else { return }

                    let initialEntries = self.initialReactionSummaryEntries(for: message)
                    menu.showReactionSummary(entries: initialEntries)

                    Task { [weak self, weak menu] in
                        guard let self else { return }
                        let resolved = await self.viewModel.reactionSummaryEntries(for: message)
                        await MainActor.run {
                            menu?.updateReactionSummary(entries: resolved)
                        }
                    }
                }
            ))
        }

        if !message.content.isRedacted && !isPendingOutgoingMessage {
            actions.append(ContextMenuAction(
                title: "Forward",
                image: UIImage(systemName: "arrowshape.turn.up.right"),
                handler: { [weak self] in
                    self?.onForwardMessage?(message)
                }
            ))
        }

        if message.isTextEditable {
            actions.append(ContextMenuAction(
                title: "Edit",
                image: UIImage(systemName: "pencil"),
                handler: { [weak self] in
                    self?.viewModel.setEditingTarget(message)
                }
            ))
        }

        if let groupCell = cellNode as? PhotoGroupMessageCellNode,
           let presentation = message.mediaGroupPresentation,
           presentation.rendersCompositeBubble,
           !isPendingOutgoingMessage,
           !message.content.isRedacted {
            if let tappedItem = groupCell.prepareContextMenuSelection(at: activationPoint) {
                let precomputedItemDeleteTarget = freezeSnapshotTarget(
                    groupCell.paintSplashTarget(
                        for: tappedItem.messageId,
                        frameInScreen: activeContextMenuItemFramesInScreen[tappedItem.messageId]
                    )
                )
                let precomputedReflowPreviews = groupCell.partialReflowPreviewImageData(
                    excluding: tappedItem.messageId
                )
                actions.append(ContextMenuAction(
                    title: "Delete Photo",
                    image: UIImage(systemName: "trash"),
                    isDestructive: true,
                    handler: { [weak self] in
                        self?.beginPartialCompositeItemDelete(
                            item: tappedItem,
                            target: precomputedItemDeleteTarget,
                            reflowPreviews: precomputedReflowPreviews
                        )
                    }
                ))
            }

            let groupItems = presentation.items.filter { $0.itemIdentifier != nil }
            if !groupItems.isEmpty {
                let groupId = presentation.id
                let groupMessageIds = Set(groupItems.map(\.messageId))
                let precomputedGroupDeleteTarget = captureSnapshotTarget(
                    from: info.node.view,
                    frameInScreen: activeContextMenuBubbleFrameInScreen
                )
                actions.append(ContextMenuAction(
                    title: "Delete Group",
                    image: UIImage(systemName: "square.stack.3d.down.forward"),
                    isDestructive: true,
                    handler: { [weak self] in
                        self?.beginCompositeGroupDelete(
                            groupId: groupId,
                            messageIds: groupMessageIds,
                            items: groupItems,
                            splashTarget: precomputedGroupDeleteTarget
                        )
                    }
                ))
            }
        } else if message.itemIdentifier != nil && !message.content.isRedacted {
            let precomputedMessageDeleteTarget = freezeSnapshotTarget(
                (cellNode as? MessageCellNode)?.paintSplashTarget(
                    frameInScreen: activeContextMenuBubbleFrameInScreen
                ) ?? captureSnapshotTarget(
                    from: info.node.view,
                    frameInScreen: activeContextMenuBubbleFrameInScreen
                )
            )
            actions.append(ContextMenuAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                isDestructive: true,
                handler: { [weak self] in
                    self?.beginMessageDelete(
                        message,
                        target: precomputedMessageDeleteTarget
                    )
                }
            ))
        }

        let menuVC = ContextMenuController(
            contentNode: info.node,
            sourceFrame: info.frame,
            actions: actions
        )
        menuVC.onDismissComplete = { [weak self, weak cellNode] in
            (cellNode as? PhotoGroupMessageCellNode)?.clearContextMenuSelection()
            cellNode?.restoreBubbleFromMenu()
            self?.unlockInteraction("contextMenu")
            self?.activeContextMenu = nil
            self?.activeContextMenuBubbleFrameInScreen = nil
            self?.activeContextMenuItemFramesInScreen = [:]
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

    private struct CopyableMessageText {
        let text: String
        let actionTitle: String
    }

    private func copyableText(for message: ChatMessage) -> CopyableMessageText? {
        guard !message.content.isRedacted else {
            return nil
        }

        if let text = message.content.textBody,
           !text.isEmpty {
            return CopyableMessageText(
                text: text,
                actionTitle: String(localized: "Copy")
            )
        }

        if let caption = normalizedCopyCaption(message.mediaGroupPresentation?.caption) {
            return CopyableMessageText(
                text: caption,
                actionTitle: String(localized: "Copy Caption")
            )
        }

        if let caption = message.content.visibleImageCaption {
            return CopyableMessageText(
                text: caption,
                actionTitle: String(localized: "Copy Caption")
            )
        }

        return nil
    }

    private func normalizedCopyCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let visible = caption
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }

    private func copyMessageText(_ message: ChatMessage) {
        guard let copyable = copyableText(for: message) else { return }
        UIPasteboard.general.string = copyable.text
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
        let tableView = tableNode.view
        if isTableRubberBanding(tableView) {
            return false
        }
        return !viewModel.isPaginating && (viewModel.hasOlderInDB || !viewModel.sdkPaginationExhausted)
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
                self.resolveServerBatchFetch(
                    context: context,
                    countBefore: countBefore,
                    attemptsRemaining: ServerBatchFetchWait.maxAttempts
                )
            }
    }

    private func resolveServerBatchFetch(
        context: ASBatchContext,
        countBefore: Int,
        attemptsRemaining: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + ServerBatchFetchWait.pollInterval
        ) { [weak self] in
            guard let self else { return }
            let page = self.viewModel.queryOlderFromDB()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if let page {
                    self.viewModel.sdkPaginationExhausted = false
                    self.viewModel.applyOlderPageFromDB(page)
                    context.completeBatchFetching(true)
                    self.batchFetchCancellable = nil
                    return
                }

                if attemptsRemaining > 1 {
                    self.resolveServerBatchFetch(
                        context: context,
                        countBefore: countBefore,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                    return
                }

                if self.viewModel.messages.count <= countBefore {
                    // The SDK often flips `isPaginating` to false before the
                    // debounced diff batcher has flushed into GRDB, so don't
                    // treat a single miss as the true history start.
                    self.viewModel.sdkPaginationExhausted = true
                }

                context.completeBatchFetching(true)
                self.batchFetchCancellable = nil
            }
        }
    }

    // MARK: - Scroll

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !isPreviewMode {
            GlassService.shared.setNeedsCapture()
        }
        guard !isTeleporting else { return }
        let isRubberBanding = isTableRubberBanding(scrollView)

        // Load newer messages when scrolling toward bottom (inverted: small contentOffset.y)
        if !viewModel.isAtLiveEdge && !isRubberBanding && scrollView.contentOffset.y < 200 {
            viewModel.loadNewerMessages()
        }

        if !isPreviewMode {
            updateScrollToLiveVisibility()
            updateDateHeaderOverlay()
        }

        if !isPreviewMode && !isRubberBanding {
            scheduleVisibleReadReceiptEvaluation()
        }
    }

    // MARK: - Smart Navigation (Journey / Teleportation)

    private func navigateToMessage(eventId: String) {
        // If message is visible on screen — smooth scroll (journey)
        if let idx = viewModel.indexOfMessage(eventId: eventId) {
            let targetIP = IndexPath(row: idx, section: 0)
            let visibleRect = node.tableNode.view.bounds
            if let cellNode = node.tableNode.nodeForRow(at: targetIP),
               visibleRect.intersects(cellNode.view.frame) {
                print("[nav] journey — already visible at idx=\(idx)")
                node.tableNode.scrollToRow(at: targetIP, at: .middle, animated: true)
                highlightMessage(eventId: eventId, delay: 0.3)
                return
            }
        }
        // Otherwise — teleport (Telegram-style snapshot slide)
        // Inverted table: higher row = older. Jumping to older → content slides down, to newer → up.
        let currentFirst = node.tableNode.indexPathsForVisibleRows().first?.row ?? 0
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
                  let idx = self.viewModel.indexOfMessage(eventId: eventId),
                  let cellNode = self.node.tableNode.nodeForRow(at: IndexPath(row: idx, section: 0))
                      as? MessageCellNode
            else { return }
            cellNode.highlightBubble()
        }
    }

    private func navigateToLive() {
        if viewModel.isAtLiveEdge && !shouldTeleportToLive() {
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
        dateHeaderOverlayManager.hide()
        // Inverted table: jump-to-older → content slides DOWN (camera pans up)
        //                  jump-to-newer → content slides UP (camera pans down)
        let sign: CGFloat = direction == .up ? 1 : -1

        let slideHeight = view.bounds.height

        // 1. Overlay snapshot in a container (clips to table bounds)
        let snapshotContainer = UIView(frame: tableView.frame)
        snapshotContainer.clipsToBounds = true
        snapshotContainer.transform = tableView.transform
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
            self?.updateDateHeaderOverlay()
            self?.scheduleVisibleReadReceiptEvaluation(delay: ReadReceipts.contentUpdateDelay)
        }
        tableLayer.add(tableAnim, forKey: "teleportIn")

        // Sustain glass capture for the full spring animation
        GlassService.shared.captureFor(duration: springTiming.settlingDuration)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartOffsetY = scrollView.contentOffset.y
        updateDateHeaderOverlay(animated: true)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView,
                                   withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard !isPreviewMode else { return }
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
        } else {
            updateDateHeaderOverlay(animated: true)
            scheduleVisibleReadReceiptEvaluation(delay: ReadReceipts.contentUpdateDelay)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        fpsBooster.stop()
        updateDateHeaderOverlay(animated: true)
        scheduleVisibleReadReceiptEvaluation(delay: ReadReceipts.contentUpdateDelay)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateDateHeaderOverlay(animated: true)
        scheduleVisibleReadReceiptEvaluation(delay: ReadReceipts.contentUpdateDelay)
    }

    private func refreshGlassSourceBinding() {
        let sourceView = node.tableNode.view
        glassNavBar.sourceView = sourceView
        glassInputBar.sourceView = sourceView
        if Self.showGlassComparison {
            glassComparison.sourceView = sourceView
        }
    }

    // MARK: - Paint Splash Delete

    private func triggerPaintSplashDelete(for message: ChatMessage) {
        viewModel.redactMessage(message)
    }

    private func handleRedactionBatch(_ batch: ChatViewModel.DetectedRedactionBatch) {
        guard !batch.messageIds.isEmpty else { return }

        guard redactionAnimationsArmed else {
            viewModel.hideMessages(batch.messageIds)
            return
        }

        // Defer if context menu is active (bubble is reparented to overlay)
        if activeContextMenu != nil {
            pendingRedactionBatches.append(batch)
            return
        }

        let immediateGroupIds = Set(
            batch.mediaGroups.compactMap { group in
                shouldCoalesceIncomingGroupRedaction(group) ? group.groupId : nil
            }
        )

        for group in batch.mediaGroups where immediateGroupIds.contains(group.groupId) {
            queueIncomingGroupRedaction(group)
        }

        let deferredIds = Set(
            batch.mediaGroups
                .filter { immediateGroupIds.contains($0.groupId) }
                .flatMap(\.redactedMessageIds)
        )
        let immediateIds = batch.messageIds.filter { !deferredIds.contains($0) }
        guard !immediateIds.isEmpty else { return }
        handleRedactedMessages(immediateIds)
    }

    private func handleRedactedMessages(_ messageIds: [String]) {
        // Defer if context menu is active (bubble is reparented to overlay)
        if activeContextMenu != nil {
            pendingRedactionBatches.append(
                ChatViewModel.DetectedRedactionBatch(messageIds: messageIds, mediaGroups: [])
            )
            return
        }

        var remainingIds = Set(messageIds)
        let pendingGroupDeletes = pendingCompositeGroupDeletes

        for (groupId, pendingDelete) in pendingGroupDeletes {
            let memberIds = pendingDelete.messageIds
            guard !memberIds.isDisjoint(with: remainingIds) else { continue }

            if viewModel.areMessagesRedacted(Array(memberIds)) {
                if !triggerCompositeGroupPaintSplashDelete(
                    forGroupId: groupId,
                    pendingDelete: pendingDelete
                ) {
                    viewModel.hideMessages(Array(memberIds))
                }
                pendingCompositeGroupDeletes.removeValue(forKey: groupId)
            }

            remainingIds.subtract(memberIds)
        }

        for messageId in remainingIds {
            if let pendingTarget = pendingAnimatedDeleteTargets.removeValue(forKey: messageId) {
                PaintSplashTrigger.trigger(in: node.tableNode, target: pendingTarget) { [weak self] in
                    self?.viewModel.hideMessage(messageId)
                }
                continue
            }

            if triggerPartialPaintSplashDelete(for: messageId) {
                continue
            }

            guard let indexPath = indexPathForMessageId(messageId) else {
                viewModel.hideMessage(messageId)
                continue
            }

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

    private func shouldCoalesceIncomingGroupRedaction(
        _ group: ChatViewModel.DetectedRedactedMediaGroup
    ) -> Bool {
        guard group.totalCount > 1 else { return false }
        if pendingCompositeGroupDeletes[group.groupId] != nil {
            return false
        }
        if group.redactedMessageIds.contains(where: { pendingAnimatedDeleteTargets[$0] != nil }) {
            return false
        }
        return true
    }

    private func queueIncomingGroupRedaction(
        _ group: ChatViewModel.DetectedRedactedMediaGroup
    ) {
        let pending: PendingIncomingCompositeGroupRedaction
        if let existing = pendingIncomingGroupRedactions[group.groupId] {
            pending = existing
            pending.redactedMessageIds.formUnion(group.redactedMessageIds)
            pending.remainingCountAfter = group.remainingCountAfter
            pending.workItem?.cancel()
        } else {
            pending = PendingIncomingCompositeGroupRedaction(
                groupId: group.groupId,
                allMessageIds: group.allMessageIds,
                totalCount: group.totalCount,
                redactedMessageIds: group.redactedMessageIds,
                remainingCountAfter: group.remainingCountAfter,
                splashTarget: captureVisibleCompositeGroupSnapshotTarget(forGroupId: group.groupId)
            )
            pendingIncomingGroupRedactions[group.groupId] = pending
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizeIncomingGroupRedaction(groupId: group.groupId)
        }
        pending.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58, execute: workItem)
    }

    private func finalizeIncomingGroupRedaction(groupId: String) {
        guard let pending = pendingIncomingGroupRedactions.removeValue(forKey: groupId) else {
            return
        }

        if pending.remainingCountAfter == 0 {
            if let splashTarget = pending.splashTarget {
                PaintSplashTrigger.trigger(in: node.tableNode, target: splashTarget) { [weak self] in
                    self?.viewModel.hideMessages(Array(pending.allMessageIds))
                }
            } else if !triggerCompositeGroupPaintSplashDelete(
                forGroupId: groupId,
                pendingDelete: PendingCompositeGroupDelete(
                    messageIds: pending.allMessageIds,
                    splashTarget: nil
                )
            ) {
                viewModel.hideMessages(Array(pending.allMessageIds))
            }
            return
        }

        handleRedactedMessages(Array(pending.redactedMessageIds))
    }

    private func captureVisibleCompositeGroupSnapshotTarget(
        forGroupId groupId: String
    ) -> PaintSplashTrigger.SnapshotTarget? {
        guard let indexPath = indexPathForCompositeGroup(groupId) else {
            return nil
        }

        guard let cellNode = node.tableNode.nodeForRow(at: indexPath) as? MessageCellNode,
              cellNode.isNodeLoaded
        else {
            return nil
        }
        let bubbleView = cellNode.bubbleNode.view
        let frameInScreen = bubbleView.convert(
            bubbleView.bounds,
            to: bubbleView.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
        )
        return captureSnapshotTarget(from: bubbleView, frameInScreen: frameInScreen)
    }

    @discardableResult
    private func triggerPartialPaintSplashDelete(for messageId: String) -> Bool {
        guard let indexPath = indexPathForCompositeItem(messageId) else {
            return false
        }

        guard let groupCell = node.tableNode.nodeForRow(at: indexPath) as? PhotoGroupMessageCellNode,
              groupCell.isNodeLoaded,
              let target = groupCell.paintSplashTarget(for: messageId)
        else {
            return false
        }

        let previews = groupCell.partialReflowPreviewImageData(excluding: messageId)
        if !previews.isEmpty {
            viewModel.registerPartialReflowPreviews(previews)
        }

        PaintSplashTrigger.trigger(in: node.tableNode, target: target) { [weak self] in
            self?.viewModel.hideMessage(messageId)
        }
        return true
    }

    @discardableResult
    private func triggerCompositeGroupPaintSplashDelete(
        forGroupId groupId: String,
        pendingDelete: PendingCompositeGroupDelete
    ) -> Bool {
        if let splashTarget = pendingDelete.splashTarget {
            PaintSplashTrigger.trigger(in: node.tableNode, target: splashTarget) { [weak self] in
                self?.viewModel.hideMessages(Array(pendingDelete.messageIds))
            }
            return true
        }

        guard let indexPath = indexPathForCompositeGroup(groupId) else {
            return false
        }

        PaintSplashTrigger.trigger(in: node.tableNode, at: indexPath) { [weak self] in
            self?.viewModel.hideMessages(Array(pendingDelete.messageIds))
        }
        return true
    }

    private func beginCompositeGroupDelete(
        groupId: String,
        messageIds: Set<String>,
        items: [MediaGroupItem],
        splashTarget: PaintSplashTrigger.SnapshotTarget?
    ) {
        guard !messageIds.isEmpty else { return }
        viewModel.registerPendingAnimatedRedactions(Array(messageIds))
        pendingCompositeGroupDeletes[groupId] = PendingCompositeGroupDelete(
            messageIds: messageIds,
            splashTarget: splashTarget
        )
        viewModel.redactMediaGroupItems(items)
    }

    private func handleRedactionFailure(
        for messageId: String,
        disposition: PendingRedactionFailureDisposition
    ) {
        pendingAnimatedDeleteTargets.removeValue(forKey: messageId)
        let affectedGroups = pendingCompositeGroupDeletes.compactMap { groupId, pendingDelete -> (String, Set<String>)? in
            pendingDelete.messageIds.contains(messageId) ? (groupId, pendingDelete.messageIds) : nil
        }

        guard !affectedGroups.isEmpty else {
            viewModel.clearPendingAnimatedRedactions([messageId])
            if disposition == .terminal {
                viewModel.restoreMessages([messageId])
            }
            return
        }

        for (groupId, messageIds) in affectedGroups {
            pendingCompositeGroupDeletes.removeValue(forKey: groupId)
            viewModel.clearPendingAnimatedRedactions(Array(messageIds))
            let alreadyRedacted = messageIds.filter { viewModel.areMessagesRedacted([$0]) }
            if !alreadyRedacted.isEmpty {
                handleRedactedMessages(Array(alreadyRedacted))
            }
            if disposition == .terminal {
                let idsToRestore = Set(messageIds).subtracting(alreadyRedacted)
                if !idsToRestore.isEmpty {
                    viewModel.restoreMessages(Array(idsToRestore))
                }
            }
        }
    }

    private func beginPartialCompositeItemDelete(
        item: MediaGroupItem,
        target: PaintSplashTrigger.SnapshotTarget?,
        reflowPreviews: [String: Data]
    ) {
        if let target {
            pendingAnimatedDeleteTargets[item.messageId] = target
        }
        if !reflowPreviews.isEmpty {
            viewModel.registerPartialReflowPreviews(reflowPreviews)
        }
        viewModel.registerPendingAnimatedRedactions([item.messageId])
        viewModel.redactMediaGroupItem(item)
    }

    private func beginMessageDelete(
        _ message: ChatMessage,
        target: PaintSplashTrigger.SnapshotTarget?
    ) {
        if let target {
            pendingAnimatedDeleteTargets[message.id] = target
        }
        viewModel.registerPendingAnimatedRedactions([message.id])
        triggerPaintSplashDelete(for: message)
    }

    private func captureSnapshotTarget(
        from sourceSnapshotView: UIView,
        frameInScreen overrideFrameInScreen: CGRect? = nil
    ) -> PaintSplashTrigger.SnapshotTarget? {
        guard sourceSnapshotView.bounds.width > 0, sourceSnapshotView.bounds.height > 0 else {
            return nil
        }

        let image = UIGraphicsImageRenderer(bounds: sourceSnapshotView.bounds).image { ctx in
            BubblePortalCaptureRenderer.renderLayerForCapture(
                sourceSnapshotView.layer,
                in: ctx.cgContext,
                clipRectInLayer: sourceSnapshotView.bounds
            )
        }
        guard image.cgImage != nil else { return nil }

        let frozenSourceView = UIView(frame: sourceSnapshotView.bounds)
        return PaintSplashTrigger.SnapshotTarget(
            sourceView: frozenSourceView,
            frameInScreen: overrideFrameInScreen ?? sourceSnapshotView.convert(
                sourceSnapshotView.bounds,
                to: sourceSnapshotView.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
            ),
            image: image,
            hideSource: {}
        )
    }

    private func freezeSnapshotTarget(
        _ target: PaintSplashTrigger.SnapshotTarget?
    ) -> PaintSplashTrigger.SnapshotTarget? {
        guard let target else { return nil }
        let frozenSourceView = UIView(
            frame: CGRect(origin: .zero, size: target.image.size)
        )
        return PaintSplashTrigger.SnapshotTarget(
            sourceView: frozenSourceView,
            frameInScreen: target.frameInScreen,
            image: target.image,
            hideSource: {}
        )
    }

    private func flushPendingRedactions() {
        guard !pendingRedactionBatches.isEmpty else { return }
        let batches = pendingRedactionBatches
        pendingRedactionBatches.removeAll()
        for batch in batches {
            handleRedactionBatch(batch)
        }
    }

    private func scheduleRedactionAnimationArming() {
        redactionAnimationArmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.redactionAnimationsArmed = true
        }
        redactionAnimationArmWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RedactionAnimations.bootstrapArmDelay,
            execute: work
        )
    }

    private func indexPathForMessage(_ message: ChatMessage) -> IndexPath? {
        indexPathForMessageId(message.id)
    }

    private func indexPathForMessageId(_ messageId: String) -> IndexPath? {
        guard let row = viewModel.rows.firstIndex(where: { $0.message?.id == messageId }) else {
            return nil
        }
        return IndexPath(row: row, section: 0)
    }

    private func indexPathForCompositeGroup(_ groupId: String) -> IndexPath? {
        guard let row = viewModel.rows.firstIndex(where: { row in
            guard let message = row.message else { return false }
            return message.mediaGroupPresentation?.rendersCompositeBubble == true
                && message.mediaGroupPresentation?.id == groupId
        }) else {
            return nil
        }
        return IndexPath(row: row, section: 0)
    }

    private func indexPathForCompositeItem(_ messageId: String) -> IndexPath? {
        guard let row = viewModel.rows.firstIndex(where: { row in
            guard let message = row.message else { return false }
            return message.mediaGroupPresentation?.rendersCompositeBubble == true
                && message.mediaGroupPresentation?.items.contains(where: { $0.messageId == messageId }) == true
        }) else {
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
        sheet.addAction(UIAlertAction(title: String(localized: "Scan"), style: .default) { [weak self] _ in
            self?.presentDocumentScanner()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))

        present(sheet, animated: true)
    }

    private func enqueueImageAttachments(_ imageDataItems: [Data]) {
        guard !imageDataItems.isEmpty,
              viewModel.editingMessage == nil else { return }
        viewModel.clearPendingForward()
        if composerController.state.hasAttachments,
           composerController.state.imageAttachments.count != composerController.state.attachments.count {
            composerController.clearAttachments()
        }
        Task { [weak self] in
            await self?.composerController.addImageData(imageDataItems)
        }
    }

    private func enqueuePastedImages(_ images: [UIImage]) {
        guard !images.isEmpty,
              viewModel.editingMessage == nil else { return }
        viewModel.clearPendingForward()
        if composerController.state.hasAttachments,
           composerController.state.imageAttachments.count != composerController.state.attachments.count {
            composerController.clearAttachments()
        }
        Task { [weak self] in
            await self?.composerController.addImages(images)
        }
    }

    private func enqueueFileAttachments(_ urls: [URL]) {
        let files = Array(urls.prefix(10))
        guard !files.isEmpty,
              viewModel.editingMessage == nil else { return }
        viewModel.clearPendingForward()
        if composerController.state.hasAttachments,
           composerController.state.fileAttachments.count != composerController.state.attachments.count {
            composerController.clearAttachments()
        }
        composerController.addFileURLs(files)
    }

    private func enqueueScannedDocumentAttachment(_ attachment: DocumentScanAttachment) {
        guard viewModel.editingMessage == nil else { return }
        viewModel.clearPendingForward()
        if composerController.state.hasAttachments,
           composerController.state.fileAttachments.count != composerController.state.attachments.count {
            composerController.clearAttachments()
        }

        let subtitle = scannedDocumentSubtitle(
            pageCount: attachment.pageCount,
            byteCount: attachment.byteCount
        )
        composerController.addFileURL(
            attachment.fileURL,
            previewImage: attachment.previewImage,
            title: attachment.filename,
            subtitle: subtitle,
            accessibilityLabel: attachment.accessibilityLabel
        )
    }

    private func scannedDocumentSubtitle(pageCount: Int, byteCount: UInt64) -> String {
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        let size = ChatComposerController.byteCountString(for: byteCount)
        return "\(pages) · \(size)"
    }

    private func presentComposerPreviewIfNeeded() {
        let state = composerController.state
        guard !state.attachments.isEmpty else {
            shouldPresentAttachmentPreviewAfterDismiss = false
            return
        }

        if state.imageAttachments.count == state.attachments.count {
            presentPhotoGroupPreviewIfNeeded()
        } else if state.fileAttachments.count == state.attachments.count {
            presentFileAttachmentPreviewIfNeeded()
        } else {
            assertionFailure("Mixed attachment drafts are unsupported")
            composerController.clearAttachments()
        }
    }

    private func presentPhotoGroupPreviewIfNeeded() {
        let state = composerController.state
        guard !state.imageAttachments.isEmpty,
              state.imageAttachments.count == state.attachments.count
        else { return }

        guard photoPreviewController == nil, filePreviewController == nil else { return }
        guard presentedViewController == nil else {
            shouldPresentAttachmentPreviewAfterDismiss = true
            return
        }
        shouldPresentAttachmentPreviewAfterDismiss = false

        let controller = PhotoGroupPreviewController(
            attachments: state.imageAttachments,
            initialCaption: glassInputBar.inputNode.currentText,
            initialCaptionPlacement: state.photoGroupCaptionPlacement
        )
        controller.onDiscard = { [weak self, weak controller] in
            guard let self else { return }
            if self.photoPreviewController === controller {
                self.photoPreviewController = nil
            }
            self.composerController.clearAttachments()
        }
        controller.onSend = { [weak self, weak controller] attachments, caption, captionPlacement, layoutOverride in
            guard let self else { return }
            if self.photoPreviewController === controller {
                self.photoPreviewController = nil
            }
            self.composerController.clearAttachments()
            self.glassInputBar.inputNode.setCurrentText("")
            let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            self.viewModel.sendComposerAttachments(
                attachments,
                caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
                captionPlacement: captionPlacement,
                layoutOverride: layoutOverride
            )
            self.scrollToLiveAfterUserSend()
        }
        photoPreviewController = controller
        glassInputBar.inputNode.textInputNode.resignFirstResponder()
        present(controller, animated: true)
    }

    private func presentFileAttachmentPreviewIfNeeded() {
        let state = composerController.state
        guard !state.fileAttachments.isEmpty,
              state.fileAttachments.count == state.attachments.count
        else { return }

        guard photoPreviewController == nil, filePreviewController == nil else { return }
        guard presentedViewController == nil else {
            shouldPresentAttachmentPreviewAfterDismiss = true
            return
        }
        shouldPresentAttachmentPreviewAfterDismiss = false

        let controller = FileAttachmentPreviewController(
            attachments: state.fileAttachments,
            initialCaption: glassInputBar.inputNode.currentText
        )
        controller.onDiscard = { [weak self, weak controller] in
            guard let self else { return }
            if self.filePreviewController === controller {
                self.filePreviewController = nil
            }
            self.composerController.clearAttachments()
        }
        controller.onSend = { [weak self, weak controller] attachments, caption in
            guard let self else { return }
            if self.filePreviewController === controller {
                self.filePreviewController = nil
            }
            self.composerController.clearAttachments()
            self.glassInputBar.inputNode.setCurrentText("")
            let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            self.viewModel.sendComposerAttachments(
                attachments,
                caption: trimmedCaption.isEmpty ? nil : trimmedCaption
            )
            self.scrollToLiveAfterUserSend()
        }
        filePreviewController = controller
        glassInputBar.inputNode.textInputNode.resignFirstResponder()
        present(controller, animated: true)
    }

    // MARK: - Document Scanner

    private func presentDocumentScanner() {
        guard viewModel.editingMessage == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let attachment = try await self.documentScanFlow.scan(from: self)
                self.enqueueScannedDocumentAttachment(attachment)
            } catch ScannerError.cancelled {
                return
            } catch {
                self.presentDocumentScannerError(error)
            }
        }
    }

    private func presentDocumentScannerError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: String(localized: "Scan Failed"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
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
        guard case .file(let source?, let filename, let mimetype, _, _) = message.content
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
        if case .image(let src, _, _, _, _) = message.content {
            source = src
        }

        let cellImageView = cell.imageNodeView
        let sourceFrame = cellImageView.convert(cellImageView.bounds, to: nil)
        let items = [
            ImageViewerController.Item(
                previewImage: image,
                mediaSource: source,
                sourceFrame: sourceFrame
            )
        ]
        presentImageViewer(items: items, initialIndex: 0)
    }

    private func presentImageViewer(for cell: PhotoGroupMessageCellNode, itemIndex: Int) {
        guard let initialImage = cell.currentImage(at: itemIndex),
              let initialSourceFrame = cell.viewerSourceFrameInWindow(at: itemIndex) else { return }
        let initialMediaSource = cell.mediaSource(at: itemIndex)

        var items: [ImageViewerController.Item] = []
        items.reserveCapacity(cell.mediaItemCount)

        for index in 0..<cell.mediaItemCount {
            let previewImage: UIImage?
            let sourceFrame: CGRect
            if index == itemIndex {
                previewImage = initialImage
                sourceFrame = initialSourceFrame
            } else {
                previewImage = cell.currentImage(at: index)
                sourceFrame = cell.viewerSourceFrameInWindow(at: index) ?? .zero
            }

            items.append(ImageViewerController.Item(
                previewImage: previewImage,
                mediaSource: cell.mediaSource(at: index),
                sourceFrame: sourceFrame
            ))
        }

        guard !items.isEmpty else {
            let items = [
                ImageViewerController.Item(
                    previewImage: initialImage,
                    mediaSource: initialMediaSource,
                    sourceFrame: initialSourceFrame
                )
            ]
            presentImageViewer(items: items, initialIndex: 0)
            return
        }

        presentImageViewer(items: items, initialIndex: itemIndex)
    }

    private func presentImageViewer(items: [ImageViewerController.Item], initialIndex: Int) {
        guard !items.isEmpty else { return }
        let viewer = ImageViewerController(items: items, initialIndex: initialIndex)
        present(viewer, animated: false) {
            viewer.animateIn(from: items[max(0, min(initialIndex, items.count - 1))].sourceFrame)
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
            if self.shouldPresentAttachmentPreviewAfterDismiss {
                self.presentComposerPreviewIfNeeded()
            }
        }
        guard !results.isEmpty else { return }

        Task {
            var imageDataItems: [Data] = []
            for result in results {
                guard let data = await loadImageData(from: result) else { continue }
                imageDataItems.append(data)
            }
            guard !imageDataItems.isEmpty else { return }
            await MainActor.run {
                self.enqueueImageAttachments(imageDataItems)
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
        enqueueFileAttachments(urls)
        DispatchQueue.main.async { [weak self] in
            if self?.shouldPresentAttachmentPreviewAfterDismiss == true {
                self?.presentComposerPreviewIfNeeded()
            }
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

// MARK: - Accessibility Reaction Summary

private final class AccessibilityReactionSummaryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyStateLabel = UILabel()
    private let onRemoveReaction: (ReactionSummaryEntry) -> Void
    private var entries: [ReactionSummaryEntry]
    private var suppressedEntryIds = Set<String>()
    private var didPostInitialFocus = false

    init(
        entries: [ReactionSummaryEntry],
        onRemoveReaction: @escaping (ReactionSummaryEntry) -> Void
    ) {
        self.entries = entries
        self.onRemoveReaction = onRemoveReaction
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Reactions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "Close"),
            style: .done,
            target: self,
            action: #selector(closeTapped)
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            AccessibilityReactionSummaryCell.self,
            forCellReuseIdentifier: AccessibilityReactionSummaryCell.reuseIdentifier
        )
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.allowsSelection = false
        view.addSubview(tableView)

        emptyStateLabel.font = .preferredFont(forTextStyle: .body)
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.text = String(localized: "No reactions yet.")

        updateEmptyState()
        preferredContentSize = CGSize(width: 360, height: 420)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPostInitialFocus else { return }
        didPostInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIAccessibility.post(
                notification: .screenChanged,
                argument: self.preferredFocusTarget
            )
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    func update(entries: [ReactionSummaryEntry]) {
        self.entries = entries.filter { !suppressedEntryIds.contains($0.id) }
        tableView.reloadData()
        updateEmptyState()
    }

    private var preferredFocusTarget: Any? {
        if let firstVisible = tableView.visibleCells.first {
            return firstVisible
        }
        if !entries.isEmpty {
            tableView.layoutIfNeeded()
            return tableView.cellForRow(at: IndexPath(row: 0, section: 0))
        }
        return emptyStateLabel
    }

    private func updateEmptyState() {
        tableView.backgroundView = entries.isEmpty ? emptyStateLabel : nil
    }

    private func remove(_ entry: ReactionSummaryEntry) {
        suppressedEntryIds.insert(entry.id)
        onRemoveReaction(entry)

        let removedIndex = entries.firstIndex { $0.id == entry.id } ?? 0
        entries.removeAll { $0.id == entry.id }
        tableView.reloadData()
        updateEmptyState()

        let nextIndex = min(removedIndex, max(entries.count - 1, 0))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target: Any?
            if self.entries.indices.contains(nextIndex) {
                target = self.tableView.cellForRow(at: IndexPath(row: nextIndex, section: 0))
            } else {
                target = self.emptyStateLabel
            }
            UIAccessibility.post(notification: .layoutChanged, argument: target)
        }
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: AccessibilityReactionSummaryCell.reuseIdentifier,
            for: indexPath
        ) as? AccessibilityReactionSummaryCell else {
            return UITableViewCell()
        }

        let entry = entries[indexPath.row]
        cell.configure(
            entry: entry,
            timeText: MessageCellHelpers.timeFormatter.string(from: entry.timestamp),
            onRemoveReaction: entry.isOwn ? { [weak self] in
                self?.remove(entry)
            } : nil
        )
        return cell
    }
}

private final class AccessibilityReactionSummaryCell: UITableViewCell {

    static let reuseIdentifier = "AccessibilityReactionSummaryCell"

    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private let reactionLabel = UILabel()
    private var onRemoveReaction: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none
        isAccessibilityElement = true
        contentView.isAccessibilityElement = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        reactionLabel.font = .systemFont(ofSize: 22)
        reactionLabel.textAlignment = .right
        reactionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        reactionLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [nameLabel, timeLabel, reactionLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        entry: ReactionSummaryEntry,
        timeText: String,
        onRemoveReaction: (() -> Void)?
    ) {
        nameLabel.text = entry.displayName
        timeLabel.text = timeText
        reactionLabel.text = entry.reactionKey
        self.onRemoveReaction = onRemoveReaction

        accessibilityTraits = .staticText
        accessibilityLabel = "\(entry.displayName), \(timeText), \(entry.reactionKey)"
        accessibilityCustomActions = onRemoveReaction.map { _ in
            [
                UIAccessibilityCustomAction(name: String(localized: "Remove reaction")) { [weak self] _ in
                    self?.onRemoveReaction?()
                    return true
                }
            ]
        }
    }
}

// MARK: - Accessibility Emoji Picker

private typealias AccessibilityEmojiCategory = (name: String, emojis: [String])

private final class AccessibilityEmojiCategoryPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private let emptyStateLabel = UILabel()
    private let onEmojiSelected: (String) -> Void
    private var filteredEmojis: [String] = []
    private var didPostInitialFocus = false

    private var query: String {
        searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private var isSearching: Bool {
        !query.isEmpty
    }

    init(onEmojiSelected: @escaping (String) -> Void) {
        self.onEmojiSelected = onEmojiSelected
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "More Emoji")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        definesPresentationContext = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "Close"),
            style: .done,
            target: self,
            action: #selector(closeTapped)
        )

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search emoji")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(
            AccessibilityEmojiPickerCell.self,
            forCellReuseIdentifier: AccessibilityEmojiPickerCell.reuseIdentifier
        )
        view.addSubview(tableView)

        emptyStateLabel.font = .preferredFont(forTextStyle: .body)
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.text = String(localized: "No emoji found.")

        updateEmptyState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPostInitialFocus else { return }
        didPostInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIAccessibility.post(notification: .screenChanged, argument: self.preferredFocusTarget)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = query
        if query.isEmpty {
            filteredEmojis = []
        } else {
            var seen = Set<String>()
            filteredEmojis = EmojiData.categories
                .flatMap(\.emojis)
                .filter { emoji in
                    let matches = emoji.contains(query) || EmojiData.names[emoji]?.contains(query) == true
                    guard matches, seen.insert(emoji).inserted else { return false }
                    return true
                }
        }
        tableView.reloadData()
        updateEmptyState()
    }

    private var preferredFocusTarget: Any? {
        tableView.layoutIfNeeded()
        return tableView.visibleCells.first
            ?? tableView.cellForRow(at: IndexPath(row: 0, section: 0))
            ?? searchController.searchBar
    }

    private func updateEmptyState() {
        tableView.backgroundView = isSearching && filteredEmojis.isEmpty ? emptyStateLabel : nil
    }

    private func selectEmoji(_ emoji: String) {
        onEmojiSelected(emoji)
        navigationController?.dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isSearching ? filteredEmojis.count : EmojiData.categories.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if isSearching {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: AccessibilityEmojiPickerCell.reuseIdentifier,
                for: indexPath
            ) as? AccessibilityEmojiPickerCell else {
                return UITableViewCell()
            }
            cell.configure(emoji: filteredEmojis[indexPath.row])
            return cell
        }

        let reuseIdentifier = "AccessibilityEmojiCategoryCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: reuseIdentifier)
        let category = EmojiData.categories[indexPath.row]
        cell.textLabel?.text = category.name
        cell.detailTextLabel?.text = "\(category.emojis.count) " + String(localized: "emoji")
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button
        cell.accessibilityLabel = category.name
        cell.accessibilityValue = "\(category.emojis.count) " + String(localized: "emoji")
        cell.accessibilityHint = String(localized: "Opens this emoji category")
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if isSearching {
            selectEmoji(filteredEmojis[indexPath.row])
            return
        }

        let category = EmojiData.categories[indexPath.row]
        let controller = AccessibilityEmojiListViewController(
            category: category,
            onEmojiSelected: onEmojiSelected
        )
        navigationController?.pushViewController(controller, animated: true)
    }
}

private final class AccessibilityEmojiListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let category: AccessibilityEmojiCategory
    private let onEmojiSelected: (String) -> Void
    private var didPostInitialFocus = false

    init(
        category: AccessibilityEmojiCategory,
        onEmojiSelected: @escaping (String) -> Void
    ) {
        self.category = category
        self.onEmojiSelected = onEmojiSelected
        super.init(nibName: nil, bundle: nil)
        title = category.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Close"),
            style: .done,
            target: self,
            action: #selector(closeTapped)
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            AccessibilityEmojiPickerCell.self,
            forCellReuseIdentifier: AccessibilityEmojiPickerCell.reuseIdentifier
        )
        view.addSubview(tableView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPostInitialFocus else { return }
        didPostInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIAccessibility.post(
                notification: .screenChanged,
                argument: self.tableView.visibleCells.first
                    ?? self.tableView.cellForRow(at: IndexPath(row: 0, section: 0))
            )
        }
    }

    @objc private func closeTapped() {
        navigationController?.dismiss(animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        category.emojis.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: AccessibilityEmojiPickerCell.reuseIdentifier,
            for: indexPath
        ) as? AccessibilityEmojiPickerCell else {
            return UITableViewCell()
        }
        cell.configure(emoji: category.emojis[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onEmojiSelected(category.emojis[indexPath.row])
        navigationController?.dismiss(animated: true)
    }
}

private final class AccessibilityEmojiPickerCell: UITableViewCell {

    static let reuseIdentifier = "AccessibilityEmojiPickerCell"

    private let emojiLabel = UILabel()
    private let nameLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .default
        isAccessibilityElement = true
        contentView.isAccessibilityElement = false
        accessibilityTraits = .button

        emojiLabel.font = .systemFont(ofSize: 30)
        emojiLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        emojiLabel.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [emojiLabel, nameLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(emoji: String) {
        let displayName = Self.displayName(for: emoji)
        emojiLabel.text = emoji
        nameLabel.text = displayName
        accessibilityLabel = displayName
        accessibilityValue = emoji
        accessibilityHint = String(localized: "Adds this reaction")
    }

    private static func displayName(for emoji: String) -> String {
        guard let rawName = EmojiData.names[emoji], !rawName.isEmpty else { return emoji }
        return rawName.capitalized
    }
}

private final class HiddenMessagePlaceholderCellNode: ASCellNode {
    override init() {
        super.init()
        selectionStyle = .none
        backgroundColor = .clear
        style.preferredSize = CGSize(width: 1, height: 0.01)
        isAccessibilityElement = false
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let spacer = ASDisplayNode()
        spacer.style.preferredSize = CGSize(width: constrainedSize.max.width, height: 0.01)
        return ASWrapperLayoutSpec(layoutElement: spacer)
    }
}
