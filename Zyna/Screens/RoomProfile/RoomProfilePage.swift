// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

struct RoomProfileRow: Equatable {
    let id: String
    let title: String
    let detail: String?
    let item: AttachmentItem?
    let isHeader: Bool
    let isAction: Bool
    var pinned: RoomPinnedItem? = nil
    var hasContent: Bool { item != nil || pinned != nil }

    static func rows(groups: [AttachmentMonthGroup]) -> [Self] {
        groups.flatMap { group in
            [Self(id: "month:\(group.id)", title: group.title, detail: nil,
                  item: nil, isHeader: true, isAction: false)] + group.items.map { item in
                if item.kind == .voice {
                    let sender = item.isOwn ? String(localized: "You") : (item.senderName ?? item.sender)
                    return Self(id: item.id, title: sender.isEmpty ? String(localized: "Voice message") : sender,
                        detail: item.date.formatted(date: .abbreviated, time: .shortened),
                        item: item, isHeader: false, isAction: true)
                }
                let size = item.sizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
                return Self(id: item.id, title: item.filename, detail: [size, item.senderName].compactMap { $0 }.joined(separator: " · "),
                            item: item, isHeader: false, isAction: true)
            }
        }
    }
}

/// Each section owns exactly one vertical scroll view. No vertical parent
/// scroll view competes with Texture's collection view.
final class RoomProfileListPage: NSObject, ASCollectionDataSource, ASCollectionDelegate {
    let node: ASCollectionNode
    var onScroll: (() -> Void)?
    var onBeginDragging: (() -> Void)?
    var onWillEndDragging: ((CGPoint, UnsafeMutablePointer<CGPoint>) -> Void)?
    var onEndDragging: (() -> Void)?
    var onSelect: ((AttachmentItem, UIImage?, CGRect) -> Void)?
    var onShowInChat: ((AttachmentItem) -> Void)?
    var onOpenPinned: ((String) -> Void)?
    var onUnpin: ((String) -> Void)?
    var onPlayerGeometryChanged: (() -> Void)?
    private(set) var bottomDockedPlayerHeight: CGFloat?
    var voicePlayback: RoomProfileVoicePlayback? {
        didSet {
            voicePlayback?.onCurrentEventChanged = { [weak self] in self?.updatePlayingPath() }
            voicePlayback?.isActive = isActive
            updatePlayingPath()
        }
    }
    private let voiceImages: RoomProfileVoiceCell.Images?
    var accessibilityID = "profile.files"
    var onLoad: (() -> Void)?
    var onRequestImage: ((AttachmentItem) -> Void)?
    var onAnchorRestored: ((CGFloat) -> Void)?
    var onNearEnd: ((Bool) -> Void)?
    var onContextInteractionChanged: ((Bool) -> Void)?
    private let flow: RoomProfileListLayout
    private var viewportBottomInset: CGFloat = 0
    private var rows: [RoomProfileRow] = []
    private var indexByID: [String: Int] = [:]
    private var pendingRows: [RoomProfileRow]?
    private var updating = false
    private let diffQueue = DispatchQueue(label: "zyna.profile.diff", qos: .userInitiated)
    // Parent layout can reenter while Texture applies a collection batch.
    // Its scope must not reenable scroll callbacks before the batch ends.
    private var layoutAdjustmentDepth = 0
    private var applyingBatch = false
    var isAdjusting: Bool { applyingBatch || layoutAdjustmentDepth > 0 }
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            voicePlayback?.isActive = isActive
            if !isActive {
                stopScrolling()
            }
            updateNearEnd()
        }
    }
    var headerHeight: CGFloat = 220 { didSet { updatePlayingViewport() } }
    var avatarExpansionHeight: CGFloat = 0
    var tabsHeight: CGFloat = 48 { didSet { updatePlayingViewport() } }
    var collapse: CGFloat = 0 { didSet { updatePlayingViewport() } }
    var restorationAnchor: RoomProfileAnchor?
    var forceLoadIds: Set<String> = []
    var fullFileThreshold = AttachmentThumbnailPlan.defaultFullFileThreshold
    private var lastNearEnd = false
    private var activeContextMenu: ListContextMenuController?
    private var contextInteractionLocked = false
    private var scrollWasEnabled = true
    private(set) var isScrollingToBeginning = false
    private var pendingScrollToBeginning: Bool?
    private var needsTypographyRefresh = false
    private lazy var fpsBooster = ScrollFPSBooster(hostView: node.view)

    init(voice: Bool = false) {
        voiceImages = voice ? RoomProfileVoiceCell.Images() : nil
        flow = RoomProfileListLayout()
        flow.minimumLineSpacing = 2
        flow.minimumInteritemSpacing = 2
        node = ASCollectionNode(collectionViewLayout: flow)
        node.collectionViewClass = RoomProfileCollectionView.self
        super.init()
        node.dataSource = self
        node.delegate = self
        node.backgroundColor = .appBG
    }

    deinit { activeContextMenu?.dismiss(animated: false) }

    var scrollView: UIScrollView { node.view }
    var inset: CGFloat { headerHeight + tabsHeight }
    var normalizedOffset: CGFloat { scrollView.contentOffset.y + inset }

    func install() {
        node.view.contentInsetAdjustmentBehavior = .never
        node.view.alwaysBounceVertical = true
        node.view.scrollsToTop = false
        node.view.accessibilityIdentifier = accessibilityID
        node.view.keyboardDismissMode = .onDrag
    }

    func layout(frame: CGRect, depth: CGFloat, bottomInset: CGFloat) {
        viewportBottomInset = bottomInset
        updatePlayingViewport()
        let sizeChanged = node.frame.size != frame.size
        if sizeChanged {
            dismissContextMenu()
            stopScrollingToBeginning()
        }
        let anchor = sizeChanged ? captureAnchor() : nil
        layoutAdjustmentDepth += 1
        defer { layoutAdjustmentDepth -= 1 }
        node.frame = frame
        scrollView.contentInset = UIEdgeInsets(top: inset, left: 0, bottom: bottomInset, right: 0)
        if sizeChanged { flow.invalidateLayout(); node.view.layoutIfNeeded() }
        padShortContent(bottomInset: bottomInset)
        setPosition(depth: depth)
        if let anchor { restore(anchor) }
    }

    /// Enough bottom padding to collapse even an empty section. This never
    /// changes the saved depth of another section.
    private func padShortContent(bottomInset: CGFloat) {
        let minimumBottom = max(bottomInset, scrollView.bounds.height - tabsHeight - scrollView.contentSize.height)
        scrollView.contentInset.bottom = minimumBottom
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: inset - collapse, left: 0, bottom: bottomInset, right: 0)
    }

    func setPosition(depth: CGFloat) {
        layoutAdjustmentDepth += 1
        defer { layoutAdjustmentDepth -= 1 }
        let y = collapse + max(0, depth) - inset
        if abs(scrollView.contentOffset.y - y) > 0.25 { scrollView.contentOffset.y = y }
        scrollView.verticalScrollIndicatorInsets.top = inset - collapse
    }

    func scrollToBeginning(animated: Bool) {
        guard !contextInteractionLocked else { return }
        guard !updating else { pendingScrollToBeginning = animated; return }
        // The vertical delegate records each animated offset. Do not save
        // zero early: a swipe may interrupt the journey partway through.
        let target = CGPoint(x: 0, y: avatarExpansionHeight - inset)
        isScrollingToBeginning = animated && abs(scrollView.contentOffset.y - target.y) > 0.25
        if isScrollingToBeginning && isActive { fpsBooster.start() } else { fpsBooster.stop() }
        scrollView.setContentOffset(target, animated: isScrollingToBeginning)
        if !isScrollingToBeginning { onScroll?(); finishUpdate() }
    }

    func stopScrollingToBeginning() {
        pendingScrollToBeginning = nil
        guard isScrollingToBeginning else { return }
        isScrollingToBeginning = false
        fpsBooster.stop()
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        onScroll?()
        finishUpdate()
    }

    func stopScrolling() {
        stopScrollingToBeginning()
        fpsBooster.stop()
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
    }

    func captureAnchor() -> RoomProfileAnchor? {
        guard !rows.isEmpty, normalizedOffset > headerHeight + 0.5 else { return nil }
        let top = scrollView.contentOffset.y + inset - collapse
        // Texture may not have mounted the new visible cells yet after a
        // programmatic move. Layout geometry is already authoritative.
        let viewport = CGRect(x: 0, y: top, width: scrollView.bounds.width,
            height: max(1, scrollView.bounds.height - inset + collapse))
        let visible = flow.naturalAttributes(in: viewport)
            .sorted { $0.indexPath < $1.indexPath }
        guard let attributes = visible.first(where: {
            let index = $0.indexPath.item
            return rows.indices.contains(index) && rows[index].hasContent && $0.frame.maxY > top
        }) else { return nil }
        let path = attributes.indexPath
        return RoomProfileAnchor(id: rows[path.item].id, previousIndex: path.item, offset: top - attributes.frame.minY)
    }

    private func restore(_ anchor: RoomProfileAnchor) {
        guard !rows.isEmpty else { return }
        let index = indexByID[anchor.id] ?? min(anchor.previousIndex, rows.count - 1)
        guard
              let attributes = flow.naturalAttributes(at: IndexPath(item: index, section: 0)) else { return }
        let maxDepth = max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height + tabsHeight)
        let depth = min(maxDepth, max(0, attributes.frame.minY + anchor.offset))
        setPosition(depth: depth)
        onAnchorRestored?(depth)
    }

    func update(_ newRows: [RoomProfileRow]) {
        guard !updating, !contextInteractionLocked, !isScrollingToBeginning else { pendingRows = newRows; return }
        updating = true
        let old = rows
        diffQueue.async { [weak self] in
            guard old != newRows else {
                DispatchQueue.main.async { self?.finishUpdate() }
                return
            }
            let oldIDs = old.map(\.id)
            let newIDs = newRows.map(\.id)
            let difference = newIDs.difference(from: oldIDs)
            var deletes: [IndexPath] = []
            var inserts: [IndexPath] = []
            for change in difference {
                switch change {
                case .remove(let index, _, _): deletes.append(IndexPath(item: index, section: 0))
                case .insert(let index, _, _): inserts.append(IndexPath(item: index, section: 0))
                }
            }
            let newByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) })
            let newIndices = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element, $0.offset) })
            let hasItems = newRows.contains { $0.hasContent }
            let deleted = Set(deletes.map(\.item))
            let reloads = old.enumerated().compactMap { index, row -> IndexPath? in
                guard !deleted.contains(index), let next = newByID[row.id], next != row else { return nil }
                return IndexPath(item: index, section: 0)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let anchor = self.captureAnchor() ?? self.restorationAnchor
                self.applyingBatch = true
                // Unpin a removed player while its old index is still valid.
                // UIKit can adjust bounds before the batch completes.
                if let id = self.voicePlayback?.currentEventID, newIndices[id] == nil {
                    self.flow.playingPath = nil
                    self.setBottomDockedPlayerHeight(nil)
                }
                self.node.performBatch(animated: false, updates: {
                    self.rows = newRows
                    self.indexByID = newIndices
                    self.node.deleteItems(at: deletes)
                    self.node.insertItems(at: inserts)
                    self.node.reloadItems(at: reloads)
                }, completion: { [weak self] _ in
                    guard let self else { return }
                    self.node.view.layoutIfNeeded()
                    self.padShortContent(bottomInset: self.node.view.safeAreaInsets.bottom)
                    if let anchor, hasItems {
                        self.restore(anchor)
                        self.restorationAnchor = nil
                    } else if !hasItems {
                        self.setPosition(depth: 0)
                        self.onAnchorRestored?(0)
                        self.restorationAnchor = nil
                    }
                    self.finishBatchAdjustment()
                })
            }
        }
    }

    private func finishBatchAdjustment() {
        // Shrinking UICollectionView content can queue a scroll correction
        // that outlives its batch completion. Cancel it even if restoring
        // the anchor left the current offset unchanged. A later animation
        // tick must not reinterpret that correction as a header gesture.
        if !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        applyingBatch = false
        updatePlayingPath()
        updateNearEnd()
        finishUpdate()
    }

    private func finishUpdate() {
        updating = false
        guard !contextInteractionLocked, !isScrollingToBeginning else { return }
        if let pending = pendingRows { pendingRows = nil; update(pending) }
        else if needsTypographyRefresh { needsTypographyRefresh = false; refreshTypography() }
        else if let animated = pendingScrollToBeginning {
            pendingScrollToBeginning = nil
            scrollToBeginning(animated: animated)
        }
    }

    func refreshTypography() {
        guard !updating, !contextInteractionLocked, !isScrollingToBeginning else { needsTypographyRefresh = true; return }
        let paths = rows.indices.map { IndexPath(item: $0, section: 0) }
        let anchor = captureAnchor()
        updating = true
        applyingBatch = true
        node.performBatch(animated: false, updates: { self.node.reloadItems(at: paths) }, completion: { [weak self] _ in
            guard let self else { return }
            self.node.view.layoutIfNeeded()
            self.padShortContent(bottomInset: self.node.view.safeAreaInsets.bottom)
            if let anchor { self.restore(anchor) }
            self.finishBatchAdjustment()
        })
    }

    func refreshImagePlans() {}

    func collectionNode(_ collectionNode: ASCollectionNode, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionNode(_ collectionNode: ASCollectionNode, nodeBlockForItemAt indexPath: IndexPath) -> ASCellNodeBlock {
        let row = rows[indexPath.item]
        let voiceImages = voiceImages
        return { [weak self] in
            if let item = row.item, item.kind == .voice, let voiceImages {
                let content = RoomProfileVoiceCell(item: item, title: row.title,
                    subtitle: row.detail ?? "", images: voiceImages)
                guard let self else { return content }
                let cell = self.contextCell(for: item, content: content)
                cell.onLayoutAttributesChanged = { [weak self, weak content] attributes in
                    let edge = (attributes as? RoomProfileListAttributes)?.dockEdge ?? .none
                    content?.setDockEdge(edge)
                    guard let self, self.voicePlayback?.currentEventID == item.id,
                          attributes.indexPath == self.flow.playingPath else { return }
                    self.setBottomDockedPlayerHeight(edge == .bottom ? attributes.frame.height : nil)
                }
                cell.accessibilityValue = content.accessibilityValue
                cell.accessibilityHint = content.accessibilityHint
                content.onAccessibilityChanged = { [weak cell] value, hint in
                    cell?.accessibilityValue = value
                    cell?.accessibilityHint = hint
                }
                content.onControlsChanged = { [weak self, weak cell, weak content] enabled in
                    guard let self, let cell, let content else { return }
                    self.updateVoiceAccessibility(cell: cell, content: content, enabled: enabled)
                }
                content.onScrubbing = { [weak self] in self?.setContextInteractionLocked($0) }
                cell.shouldBeginContextInteraction = { [weak cell, weak content] point in
                    guard let cell, let content else { return false }
                    return !content.containsControl(at: cell.view.convert(point, to: content.view))
                }
                content.onVisibilityChanged = { [weak self, weak content] visible in
                    guard let content else { return }
                    self?.voicePlayback?.setVisible(visible, cell: content)
                }
                return cell
            }
            let cell = RoomProfileTextCell(title: row.title, detail: row.detail, isHeader: row.isHeader,
                isAction: row.isAction, isError: row.pinned?.unpinError != nil)
            if let item = row.item { return self?.contextCell(for: item, content: cell) ?? cell }
            if let pinned = row.pinned { return self?.contextCell(for: pinned, content: cell) ?? cell }
            return cell
        }
    }

    func collectionNode(_ collectionNode: ASCollectionNode, constrainedSizeForItemAt indexPath: IndexPath) -> ASSizeRange {
        let width = max(1, collectionNode.bounds.width)
        let row = rows[indexPath.item]
        let base: CGFloat = row.isHeader ? 40 : (row.item == nil ? 104 : 76)
        let height = row.item?.kind == .voice ? RoomProfileVoiceCell.rowHeight(width: width) : UIFontMetrics.default.scaledValue(for: base)
        return ASSizeRange(min: CGSize(width: width, height: height), max: CGSize(width: width, height: height))
    }

    func collectionNode(_ collectionNode: ASCollectionNode, didSelectItemAt indexPath: IndexPath) {
        guard rows.indices.contains(indexPath.item) else { return }
        let row = rows[indexPath.item]
        if row.hasContent {
            (collectionNode.nodeForItem(at: indexPath) as? ListContextMenuCellNode)?.onQuickTap?()
        } else if row.isAction { onLoad?() }
    }

    func collectionNode(_ collectionNode: ASCollectionNode, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // Voice's context source and its controls own taps. Letting the
        // collection select as well could toggle playback after seeking.
        rows.indices.contains(indexPath.item) && rows[indexPath.item].item?.kind != .voice
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjusting else { return }
        onScroll?()
        updateNearEnd()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { false }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onBeginDragging?()
        stopScrollingToBeginning()
        if isActive { fpsBooster.start() }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        onWillEndDragging?(velocity, targetContentOffset)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { fpsBooster.stop() }
        onEndDragging?()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { fpsBooster.stop() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        fpsBooster.stop()
        guard isScrollingToBeginning else { return }
        isScrollingToBeginning = false
        onScroll?()
        finishUpdate()
    }

    func updateNearEnd() {
        let near = isActive && scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 300
        guard near != lastNearEnd else { return }
        lastNearEnd = near
        onNearEnd?(near)
    }

    private func updatePlayingPath() {
        guard !contextInteractionLocked, !applyingBatch else { return }
        let path = voicePlayback?.currentEventID.flatMap { id in
            indexByID[id].map { IndexPath(item: $0, section: 0) }
        }
        guard path != flow.playingPath else { return }
        flow.playingPath = path
        if path == nil { setBottomDockedPlayerHeight(nil) }
    }

    private func setBottomDockedPlayerHeight(_ height: CGFloat?) {
        guard bottomDockedPlayerHeight != height else { return }
        bottomDockedPlayerHeight = height
        onPlayerGeometryChanged?()
    }

    private func updatePlayingViewport() {
        flow.visibleInsets = UIEdgeInsets(top: inset - collapse, left: 0, bottom: viewportBottomInset, right: 0)
    }

    private func updateVoiceAccessibility(cell: ListContextMenuCellNode, content: RoomProfileVoiceCell, enabled: Bool) {
        cell.accessibilityTraits = enabled ? [.button, .adjustable] : .button
        cell.onAccessibilityAdjust = { [weak content] forward in content?.adjustPlayback(forward: forward) }
        var actions = [UIAccessibilityCustomAction(name: String(localized: "Show in Chat", table: "RoomProfile")) { [weak self, weak content] _ in
            guard let self, let content else { return false }
            self.onShowInChat?(content.item)
            return true
        }]
        if enabled {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Stop playback", table: "RoomProfile")) { [weak content] _ in
                guard let content else { return false }
                content.stopPlayback()
                return true
            })
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Playback speed")) { [weak content] _ in
                guard let content else { return false }
                content.changeSpeed()
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .announcement,
                        argument: String(localized: "Playback speed") + ", " + content.rateTitle)
                }
                return true
            })
        }
        cell.setContextAccessibilityActions(actions)
    }
}

extension RoomProfileListPage {
    private func contextCell(for item: RoomPinnedItem, content: ASCellNode) -> ListContextMenuCellNode {
        let cell = ListContextMenuCellNode(contentNode: content)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = content.accessibilityLabel
        cell.accessibilityTraits = item.canOpen ? .button : .staticText
        cell.onQuickTap = { [weak self] in
            guard let self, !self.contextInteractionLocked, item.canOpen else { return }
            self.onOpenPinned?(item.eventId)
        }
        cell.onContextMenuActivated = { [weak self, weak cell] point in
            guard let self, let cell else { return }
            var actions: [ContextMenuAction] = []
            if item.canOpen {
                actions.append(ContextMenuAction(title: String(localized: "Show in Chat", table: "RoomProfile"),
                    image: AppIcon.bubbleLeft.template(size: 18)) { [weak self] in self?.onOpenPinned?(item.eventId) })
            }
            if item.canUnpin {
                actions.append(ContextMenuAction(title: String(localized: "Unpin"),
                    image: AppIcon.pinSlash.template(size: 18)) { [weak self] in self?.onUnpin?(item.eventId) })
            }
            self.presentContextMenu(id: item.eventId, cell: cell, point: point, actions: actions)
        }
        cell.onDragChanged = { [weak self] in self?.activeContextMenu?.trackFinger(at: $0) }
        cell.onDragEnded = { [weak self] in self?.activeContextMenu?.releaseFinger(at: $0) }
        cell.onInteractionLockChanged = { [weak self] in self?.setContextInteractionLocked($0) }
        var actions: [UIAccessibilityCustomAction] = []
        if item.canOpen {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Show in Chat", table: "RoomProfile")) { [weak self] _ in
                self?.onOpenPinned?(item.eventId); return self != nil
            })
        }
        if item.canUnpin {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Unpin")) { [weak self] _ in
                self?.onUnpin?(item.eventId); return self != nil
            })
        }
        cell.setContextAccessibilityActions(actions)
        return cell
    }

    private func contextCell(for item: AttachmentItem, content: ASCellNode) -> ListContextMenuCellNode {
        let cell = ListContextMenuCellNode(contentNode: content)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = content.accessibilityLabel
        cell.accessibilityTraits = .button
        cell.onQuickTap = { [weak self, weak cell] in
            guard let self, let cell, !self.contextInteractionLocked else { return }
            self.onSelect?(item, nil, cell.view.convert(cell.bounds, to: nil))
        }
        cell.onContextMenuActivated = { [weak self, weak cell] point in
            guard let cell else { return }
            self?.presentContextMenu(for: item, cell: cell, point: point)
        }
        cell.onDragChanged = { [weak self] point in self?.activeContextMenu?.trackFinger(at: point) }
        cell.onDragEnded = { [weak self] point in self?.activeContextMenu?.releaseFinger(at: point) }
        cell.onInteractionLockChanged = { [weak self] locked in self?.setContextInteractionLocked(locked) }
        cell.setContextAccessibilityActions([
            UIAccessibilityCustomAction(name: String(localized: "Show in Chat", table: "RoomProfile")) { [weak self] _ in
                guard let self else { return false }
                self.onShowInChat?(item)
                return true
            }
        ])
        return cell
    }

    private func presentContextMenu(for item: AttachmentItem, cell: ListContextMenuCellNode, point: CGPoint) {
        let action = ContextMenuAction(title: String(localized: "Show in Chat", table: "RoomProfile"),
            image: AppIcon.bubbleLeft.template(size: 18)) { [weak self] in self?.onShowInChat?(item) }
        presentContextMenu(id: item.id, cell: cell, point: point, actions: [action])
    }

    private func presentContextMenu(id: String, cell: ListContextMenuCellNode, point: CGPoint, actions: [ContextMenuAction]) {
        guard !actions.isEmpty, isActive, activeContextMenu == nil, !updating, indexByID[id] != nil,
              let window = node.view.window, window.windowScene != nil else {
            cell.cancelContextMenuActivation()
            return
        }
        setContextInteractionLocked(true)
        let source = cell.extractContentForMenu(in: window.coordinateSpace)
        let menu = ListContextMenuController(contentNode: source.node, sourceFrame: source.frame,
            anchorPoint: cell.view.convert(point, to: window), actions: actions)
        // Keep this specific cell alive through extraction and restoration.
        // Catalog edits wait until its content is back in the collection.
        menu.onDismissComplete = { [weak self, cell] in
            cell.restoreContentFromMenu()
            self?.activeContextMenu = nil
            self?.setContextInteractionLocked(false)
        }
        activeContextMenu = menu
        menu.show(in: window)
    }

    func dismissContextMenu() { activeContextMenu?.dismiss(animated: false) }

    private func setContextInteractionLocked(_ locked: Bool) {
        guard locked != contextInteractionLocked else { return }
        contextInteractionLocked = locked
        if locked {
            stopScrollingToBeginning()
            fpsBooster.stop()
            scrollWasEnabled = scrollView.isScrollEnabled
            scrollView.isScrollEnabled = false
        } else {
            scrollView.isScrollEnabled = scrollWasEnabled
        }
        onContextInteractionChanged?(locked)
        if !locked { updatePlayingPath() }
        if !locked, !updating { finishUpdate() }
    }
}
