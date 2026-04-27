//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

class RoomsViewController: ASDKViewController<ASDisplayNode> {

    private let viewModel = RoomsViewModel()
    private let tableNode = ASTableNode()
    private var cancellables = Set<AnyCancellable>()
    private lazy var fpsBooster = ScrollFPSBooster(hostView: tableNode.view)

    var onChatSelected: ((Room) -> Void)? {
        get { viewModel.onChatSelected }
        set { viewModel.onChatSelected = newValue }
    }

    var onChatPreviewRequested: ((Room, CGRect?) -> Void)?
    var onComposeTapped: (() -> Void)?

    private weak var previewPressRecognizer: UILongPressGestureRecognizer?
    private lazy var previewPressInteraction = RoomsPreviewPressInteraction(tableNode: tableNode)
    private var suppressSelectionIndexPath: IndexPath?
    private var previewResolutionGeneration = 0
    private var pendingPreviewResolutionGeneration: Int?

    override init() {
        super.init(node: RoomsScreenNode())

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
        node.backgroundColor = UIColor.systemBackground

        // Manual subnode management — automaticallyManagesSubnodes
        // would fight with our manual frame setting in viewDidLayoutSubviews.
        node.automaticallyManagesSubnodes = false
        node.addSubnode(tableNode)
    }

    private func bindViewModel() {
        viewModel.onTableUpdate = { [weak self] update in
            self?.applyTableUpdate(update)
        }

        viewModel.onInPlacePresence = { [weak self] updates in
            guard let self else { return }
            for (indexPath, isOnline) in updates {
                guard let cell = self.tableNode.nodeForRow(at: indexPath) as? RoomsCellNode else { continue }
                cell.updatePresence(isOnline: isOnline)
            }
        }

        MatrixClientService.shared.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .syncing:
                    self?.glassTopBar.subtitle = nil
                case .error:
                    self?.glassTopBar.subtitle = "Connection error"
                default:
                    self?.glassTopBar.subtitle = "Connecting..."
                }
            }
            .store(in: &cancellables)
    }

    private func applyTableUpdate(_ update: RoomsTableUpdate) {
        previewPressInteraction.cancel(animated: false)

        switch update {
        case .none:
            break
        case .reload:
            tableNode.reloadData()
        case .batch(let deletions, let insertions, let reloads):
            tableNode.performBatch(animated: true, updates: {
                if !deletions.isEmpty {
                    tableNode.deleteRows(at: deletions, with: .fade)
                }
                if !insertions.isEmpty {
                    tableNode.insertRows(at: insertions, with: .fade)
                }
                if !reloads.isEmpty {
                    tableNode.reloadRows(at: reloads, with: .none)
                }
            }, completion: nil)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.captureFor(duration: 0.5)
        viewModel.registerPresence()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        previewPressInteraction.cancel(animated: false)
        viewModel.unregisterPresence()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableNode.view.separatorStyle = .none
        tableNode.view.keyboardDismissMode = .onDrag

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tableNode.view.addGestureRecognizer(tap)

        previewPressInteraction.onActivate = { [weak self] indexPath, sourceFrame in
            self?.activateChatPreview(at: indexPath, sourceFrame: sourceFrame)
        }

        let previewPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(chatPreviewLongPressed(_:))
        )
        previewPress.minimumPressDuration = 0
        previewPress.cancelsTouchesInView = false
        previewPress.delegate = self
        tableNode.view.addGestureRecognizer(previewPress)
        previewPressRecognizer = previewPress

        setupHeaderBar()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func chatPreviewLongPressed(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: tableNode.view)

        switch gesture.state {
        case .began:
            previewPressInteraction.begin(at: point)
        case .changed:
            previewPressInteraction.update(to: point)
        case .cancelled, .failed, .ended:
            previewPressInteraction.cancel()
            clearSelectionSuppressionSoon()
        default:
            break
        }
    }

    private func activateChatPreview(at indexPath: IndexPath, sourceFrame: CGRect?) {
        guard viewModel.chats.indices.contains(indexPath.row) else { return }

        previewResolutionGeneration += 1
        let generation = previewResolutionGeneration
        pendingPreviewResolutionGeneration = generation
        suppressSelectionIndexPath = indexPath
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if self.pendingPreviewResolutionGeneration == generation {
                self.pendingPreviewResolutionGeneration = nil
            }
        }

        viewModel.resolveChat(at: indexPath.row) { [weak self] room in
            guard let self,
                  self.pendingPreviewResolutionGeneration == generation
            else { return }
            self.pendingPreviewResolutionGeneration = nil
            self.onChatPreviewRequested?(room, sourceFrame)
        }
    }

    private func clearSelectionSuppressionSoon() {
        guard let indexPath = suppressSelectionIndexPath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard self?.suppressSelectionIndexPath == indexPath else { return }
            self?.suppressSelectionIndexPath = nil
        }
    }

    // MARK: - Glass Top Bar

    private let glassTopBar = GlassTopBar()

    private func setupHeaderBar() {
        glassTopBar.sourceView = tableNode.view
        glassTopBar.backdropClearColor = .systemBackground

        let composeIcon = AppIcon.compose.rendered(size: 17, weight: .medium, color: AppColor.accent)

        glassTopBar.items = [
            .title(text: "Chats test", subtitle: nil),
            .circleButton(icon: composeIcon, accessibilityLabel: "New chat", action: { [weak self] in
                self?.onComposeTapped?()
            })
        ]

        node.addSubnode(glassTopBar)
        (node as? RoomsScreenNode)?.glassTopBar = glassTopBar
        (node as? RoomsScreenNode)?.tableNode = tableNode
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableNode.frame = node.bounds
        glassTopBar.updateLayout(in: view)

        let covered = glassTopBar.coveredHeight
        if tableNode.contentInset.top != covered {
            tableNode.contentInset.top = covered
            tableNode.view.verticalScrollIndicatorInsets.top = covered
        }
    }
}

// MARK: - Table Node Data Source & Delegate

extension RoomsViewController: ASTableDataSource, ASTableDelegate {

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
        if suppressSelectionIndexPath == indexPath {
            suppressSelectionIndexPath = nil
            return
        }
        view.endEditing(true)
        viewModel.selectChat(at: indexPath.row)
    }
}

extension RoomsViewController {
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

// MARK: - 120fps Scroll Boost

extension RoomsViewController {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        previewPressInteraction.cancelForScroll()
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
}

extension RoomsViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let previewPressRecognizer, gestureRecognizer === previewPressRecognizer else { return true }
        guard !tableNode.view.isDragging, !tableNode.view.isDecelerating else { return false }

        let point = gestureRecognizer.location(in: tableNode.view)
        guard let indexPath = tableNode.indexPathForRow(at: point),
              viewModel.chats.indices.contains(indexPath.row)
        else { return false }

        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        guard let previewPressRecognizer, gestureRecognizer === previewPressRecognizer else { return false }
        return other === tableNode.view.panGestureRecognizer
    }
}

private final class RoomsPreviewPressInteraction {
    private enum Metrics {
        static let feedbackDelay: TimeInterval = 0.06
        static let activationDelay: TimeInterval = 0.34
        static let movementCancelDistance: CGFloat = 10
        static let allowedCellExitInset: CGFloat = 24
        static let pressedScale: CGFloat = 0.965
        static let pressDuration: TimeInterval = 0.12
        static let restoreDuration: TimeInterval = 0.16
    }

    private weak var tableNode: ASTableNode?
    private weak var activeCellNode: ASCellNode?
    private var activeIndexPath: IndexPath?
    private var startPoint: CGPoint = .zero
    private var feedbackWork: DispatchWorkItem?
    private var activationWork: DispatchWorkItem?
    private var animator: UIViewPropertyAnimator?
    private weak var suspendedScrollView: UIScrollView?
    private var suspendedScrollWasEnabled = true

    var onActivate: ((IndexPath, CGRect?) -> Void)?

    init(tableNode: ASTableNode) {
        self.tableNode = tableNode
    }

    func begin(at point: CGPoint) {
        cancel(animated: false)

        guard let tableNode,
              let indexPath = tableNode.indexPathForRow(at: point),
              let cellNode = tableNode.nodeForRow(at: indexPath)
        else { return }

        activeIndexPath = indexPath
        activeCellNode = cellNode
        startPoint = point

        let feedbackWork = DispatchWorkItem { [weak self, weak cellNode] in
            guard let self,
                  self.activeIndexPath == indexPath,
                  let cellNode
            else { return }
            self.animate(
                cellNode.view,
                to: CGAffineTransform(scaleX: Metrics.pressedScale, y: Metrics.pressedScale),
                duration: Metrics.pressDuration
            )
        }
        self.feedbackWork = feedbackWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.feedbackDelay, execute: feedbackWork)

        let work = DispatchWorkItem { [weak self] in
            self?.activate()
        }
        activationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.activationDelay, execute: work)
    }

    func update(to point: CGPoint) {
        guard activeIndexPath != nil else { return }
        guard let tableNode else {
            cancel()
            return
        }

        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        let didMoveTowardScroll = hypot(dx, dy) > Metrics.movementCancelDistance && abs(dy) > abs(dx)
        if tableNode.view.isDragging || tableNode.view.isDecelerating || didMoveTowardScroll {
            cancel()
            return
        }

        if let cellView = activeCellNode?.view {
            let pointInCell = tableNode.view.convert(point, to: cellView)
            let allowedBounds = cellView.bounds.insetBy(
                dx: -Metrics.allowedCellExitInset,
                dy: -Metrics.allowedCellExitInset
            )
            if !allowedBounds.contains(pointInCell) {
                cancel()
            }
        }
    }

    func cancelForScroll() {
        guard activeIndexPath != nil,
              tableNode?.view.isDragging == true
        else { return }
        cancel()
    }

    func cancel(animated: Bool = true) {
        releaseScrollSuspension()
        feedbackWork?.cancel()
        feedbackWork = nil
        activationWork?.cancel()
        activationWork = nil

        if let cellView = activeCellNode?.view {
            restore(cellView, animated: animated)
        }

        activeIndexPath = nil
        activeCellNode = nil
    }

    private func activate() {
        feedbackWork?.cancel()
        feedbackWork = nil
        activationWork = nil

        guard let tableNode,
              let indexPath = activeIndexPath,
              tableNode.view.isDragging == false,
              tableNode.view.isDecelerating == false
        else {
            cancel()
            return
        }

        let sourceFrame = previewSourceFrame(for: indexPath)
        suspendScrollForActiveTouch()
        if let cellView = activeCellNode?.view {
            restore(cellView, animated: true)
        }

        activeIndexPath = nil
        activeCellNode = nil
        onActivate?(indexPath, sourceFrame)
    }

    private func previewSourceFrame(for indexPath: IndexPath) -> CGRect? {
        guard let tableNode else { return nil }

        if let cellNode = tableNode.nodeForRow(at: indexPath), cellNode.isNodeLoaded {
            return cellNode.view.convert(cellNode.view.bounds, to: nil)
        }

        let rect = tableNode.view.rectForRow(at: indexPath)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return tableNode.view.convert(rect, to: nil)
    }

    private func suspendScrollForActiveTouch() {
        guard suspendedScrollView == nil,
              let scrollView = tableNode?.view
        else { return }

        suspendedScrollView = scrollView
        suspendedScrollWasEnabled = scrollView.isScrollEnabled
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        scrollView.isScrollEnabled = false
    }

    private func releaseScrollSuspension() {
        guard let scrollView = suspendedScrollView else { return }
        scrollView.isScrollEnabled = suspendedScrollWasEnabled
        suspendedScrollView = nil
        suspendedScrollWasEnabled = true
    }

    private func restore(_ view: UIView, animated: Bool) {
        if animated {
            animate(view, to: .identity, duration: Metrics.restoreDuration)
        } else {
            animator?.stopAnimation(true)
            animator = nil
            view.transform = .identity
        }
    }

    private func animate(_ view: UIView, to transform: CGAffineTransform, duration: TimeInterval) {
        animator?.stopAnimation(true)
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
            view.transform = transform
        }
        self.animator = animator
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, self.animator === animator else { return }
            self.animator = nil
        }
        animator.startAnimation()
    }
}

// MARK: - Screen node with accessibility-friendly element order

/// Glass top bar must be first in the accessibility tree so VoiceOver
/// hit-tests it before the table cells visually behind it.
final class RoomsScreenNode: ScreenNode {
    weak var glassTopBar: ASDisplayNode?
    weak var tableNode: ASDisplayNode?

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar?.view, bar.superview === view {
                elements.append(bar)
            }
            if let table = tableNode?.view {
                elements.append(table)
            }
            return elements
        }
        set { }
    }
}
