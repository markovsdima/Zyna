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

    static func rows(groups: [AttachmentMonthGroup]) -> [Self] {
        groups.flatMap { group in
            [Self(id: "month:\(group.id)", title: group.title, detail: nil,
                  item: nil, isHeader: true, isAction: false)] + group.items.map { item in
                let size = item.sizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
                return Self(id: item.id, title: item.filename, detail: [size, item.senderName].compactMap { $0 }.joined(separator: " · "),
                            item: item, isHeader: false, isAction: true)
            }
        }
    }
}

/// Each section owns exactly one vertical scroll view. No vertical parent
/// scroll view competes with Texture's collection view.
final class RoomProfileFilePage: NSObject, ASCollectionDataSource, ASCollectionDelegate {
    let node: ASCollectionNode
    var onScroll: (() -> Void)?
    var onSelect: ((AttachmentItem, UIImage?, CGRect) -> Void)?
    var onShowInChat: ((AttachmentItem) -> Void)?
    var onLoad: (() -> Void)?
    var onRequestImage: ((AttachmentItem) -> Void)?
    var onAnchorRestored: ((CGFloat) -> Void)?
    var onNearEnd: ((Bool) -> Void)?
    var onContextInteractionChanged: ((Bool) -> Void)?
    private let flow: UICollectionViewFlowLayout
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
            if !isActive {
                stopScrollingToBeginning()
                fpsBooster.stop()
                scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            }
            updateNearEnd()
        }
    }
    var headerHeight: CGFloat = 220
    var tabsHeight: CGFloat = 48
    var collapse: CGFloat = 0
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

    override init() {
        flow = UICollectionViewFlowLayout()
        flow.minimumLineSpacing = 2
        flow.minimumInteritemSpacing = 2
        node = ASCollectionNode(collectionViewLayout: flow)
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
        node.view.accessibilityIdentifier = "profile.files"
        node.view.keyboardDismissMode = .onDrag
    }

    func layout(frame: CGRect, depth: CGFloat, bottomInset: CGFloat) {
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
        let target = CGPoint(x: 0, y: -tabsHeight)
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

    func captureAnchor() -> RoomProfileAnchor? {
        guard !rows.isEmpty, normalizedOffset > headerHeight + 0.5 else { return nil }
        let top = scrollView.contentOffset.y + inset - collapse
        // Texture may not have mounted the new visible cells yet after a
        // programmatic move. Layout geometry is already authoritative.
        let viewport = CGRect(x: 0, y: top, width: scrollView.bounds.width,
            height: max(1, scrollView.bounds.height - inset + collapse))
        let visible = (flow.layoutAttributesForElements(in: viewport) ?? [])
            .sorted { $0.indexPath < $1.indexPath }
        guard let attributes = visible.first(where: {
            let index = $0.indexPath.item
            return rows.indices.contains(index) && rows[index].item != nil && $0.frame.maxY > top
        }) else { return nil }
        let path = attributes.indexPath
        return RoomProfileAnchor(id: rows[path.item].id, previousIndex: path.item, offset: top - attributes.frame.minY)
    }

    private func restore(_ anchor: RoomProfileAnchor) {
        guard !rows.isEmpty else { return }
        let index = indexByID[anchor.id] ?? min(anchor.previousIndex, rows.count - 1)
        guard
              let attributes = flow.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { return }
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
            let hasItems = newRows.contains { $0.item != nil }
            let deleted = Set(deletes.map(\.item))
            let reloads = old.enumerated().compactMap { index, row -> IndexPath? in
                guard !deleted.contains(index), let next = newByID[row.id], next != row else { return nil }
                return IndexPath(item: index, section: 0)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let anchor = self.captureAnchor() ?? self.restorationAnchor
                self.applyingBatch = true
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
        return { [weak self] in
            let cell = RoomProfileTextCell(title: row.title, detail: row.detail, isHeader: row.isHeader, isAction: row.isAction)
            if let item = row.item { return self?.contextCell(for: item, content: cell) ?? cell }
            return cell
        }
    }

    func collectionNode(_ collectionNode: ASCollectionNode, constrainedSizeForItemAt indexPath: IndexPath) -> ASSizeRange {
        let width = max(1, collectionNode.bounds.width)
        let row = rows[indexPath.item]
        let base: CGFloat = row.isHeader ? 40 : (row.item == nil ? 104 : 76)
        let height = UIFontMetrics.default.scaledValue(for: base)
        return ASSizeRange(min: CGSize(width: width, height: height), max: CGSize(width: width, height: height))
    }

    func collectionNode(_ collectionNode: ASCollectionNode, didSelectItemAt indexPath: IndexPath) {
        guard rows.indices.contains(indexPath.item) else { return }
        let row = rows[indexPath.item]
        if row.item != nil {
            (collectionNode.nodeForItem(at: indexPath) as? ListContextMenuCellNode)?.onQuickTap?()
        } else if row.isAction { onLoad?() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjusting else { return }
        onScroll?()
        updateNearEnd()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { false }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stopScrollingToBeginning()
        if isActive { fpsBooster.start() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { fpsBooster.stop() }
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
}

extension RoomProfileFilePage {
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
        guard isActive, activeContextMenu == nil, !updating, indexByID[item.id] != nil,
              let window = node.view.window, window.windowScene != nil else {
            cell.cancelContextMenuActivation()
            return
        }
        setContextInteractionLocked(true)
        let source = cell.extractContentForMenu(in: window.coordinateSpace)
        let action = ContextMenuAction(title: String(localized: "Show in Chat", table: "RoomProfile"),
            image: UIImage(systemName: "bubble.left")) { [weak self] in self?.onShowInChat?(item) }
        let menu = ListContextMenuController(contentNode: source.node, sourceFrame: source.frame,
            anchorPoint: cell.view.convert(point, to: window), actions: [action])
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
        if !locked, !updating { finishUpdate() }
    }
}
