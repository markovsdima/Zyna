//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG || CHAT_LIST_PLAYGROUND
import AsyncDisplayKit
import UIKit

/// UIScrollView supplies native motion; the visible nodes belong to our
/// viewport. A page changes logical coordinates without moving the anchor
/// on screen. There is no UITableView restoration state to compensate.
final class ChatPlaygroundCustomList: NSObject, UIScrollViewDelegate {
    let node = ASDisplayNode()
    let scrollView = UIScrollView()
    private let contentNode = ASDisplayNode()
    private let preparation: ChatPlaygroundPreparation
    private(set) var geometry = ChatListGeometry()
    private(set) var offset: CGFloat = 0
    private(set) var insets = UIEdgeInsets.zero
    private var items: [ChatPlaygroundItem] = []
    private var nodes: [String: ChatPlaygroundRowNode] = [:]
    private var ready: [String: ChatPlaygroundRowNode] = [:]
    private var attached: [String: ChatPlaygroundRowNode] = [:]
    private var pending = Set<String>()
    private var installationLink: DisplayLinkToken?
    private var visibleRange: Range<Int>?
    private var requestedRange: Range<Int>?
    private var hierarchyDirty = true
    private var revision = 0
    private var lastMotorOffset: CGFloat = 0
    private var motorBase: CGFloat = 0
    private var ignoringMotion = false
    private var updatingNodes = false
    private var size = CGSize.zero
    private var snapshotWidth: CGFloat = 0
    private let motorSpan: CGFloat = 20_000
    var onScroll: (() -> Void)?
    var onMotionChanged: ((ChatPlaygroundMotion) -> Void)?

    // Keep cells directly under the capture source so GlassService retains
    // its per-cell culling, even though only this container moves on scroll.
    var captureView: UIView { contentNode.view }

    init(preparation: ChatPlaygroundPreparation) {
        self.preparation = preparation
        super.init()
        node.backgroundColor = AppColor.chatBackground
        node.clipsToBounds = true
        contentNode.clipsToBounds = true
        node.addSubnode(contentNode)
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.isHidden = true
        node.view.addSubview(scrollView)
        node.view.addGestureRecognizer(scrollView.panGestureRecognizer)
    }

    func updateViewport(size: CGSize, insets: UIEdgeInsets) {
        guard self.size != size || self.insets != insets else { return }
        let oldLimits = geometry.limits(viewport: self.size.height, insets: self.insets)
        let pinned = abs(offset - oldLimits.upperBound) < 3
        self.size = size
        self.insets = insets
        node.frame = CGRect(origin: .zero, size: size)
        ignoringMotion = true
        scrollView.frame = node.bounds
        ignoringMotion = false
        contentNode.frame = CGRect(origin: .zero, size: size)
        let limits = geometry.limits(viewport: size.height, insets: insets)
        offset = pinned ? limits.upperBound : min(limits.upperBound, max(limits.lowerBound, offset))
        hierarchyDirty = true
        requestedRange = nil
        updateMotor()
        updateNodes()
    }

    func apply(
        _ snapshot: ChatPlaygroundSnapshot, destination: ChatListDestination,
        completion: @escaping () -> Void
    ) {
        revision += 1
        pending.removeAll()
        ready.removeAll()
        requestedRange = nil
        hierarchyDirty = true
        let nextGeometry = snapshot.geometry(preserving: items, geometry: geometry, width: snapshotWidth)
        let oldItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let newItems = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        for id in Array(nodes.keys) {
            if let old = oldItems[id], let next = newItems[id],
               old.hasSameLayout(as: next), snapshot.width == snapshotWidth { continue }
            nodes.removeValue(forKey: id)?.removeFromSupernode()
        }
        offset = nextGeometry.offset(
            replacing: geometry, current: offset, viewport: size.height,
            insets: insets, destination: destination
        )
        geometry = nextGeometry
        snapshotWidth = snapshot.width
        items = snapshot.items
        let preload = preloadRange()
        for index in preload {
            let id = items[index].id
            if nodes[id] == nil, let prepared = snapshot.preparedNodes[id] { ready[id] = prepared }
        }
        updateMotor()
        updateNodes()
        onScroll?()
        completion()
    }

    func scroll(to destination: ChatListDestination) {
        offset = geometry.offset(
            replacing: geometry, current: offset, viewport: size.height,
            insets: insets, destination: destination
        )
        updateMotor()
        updateNodes()
        onScroll?()
    }

    func rowNode(id: String) -> ChatPlaygroundRowNode? { nodes[id] }

    private func preloadRange() -> Range<Int> {
        geometry.range(in: CGRect(
            x: 0, y: offset - size.height * 3,
            width: size.width, height: size.height * 7
        ))
    }

    private func retentionRange() -> Range<Int> {
        geometry.range(in: CGRect(
            x: 0, y: offset - size.height * 6,
            width: size.width, height: size.height * 13
        ))
    }

    private func currentVisibleRange() -> Range<Int> {
        geometry.range(in: CGRect(x: 0, y: offset, width: size.width, height: size.height))
    }

    private func install(_ row: ChatPlaygroundRowNode, id: String) {
        if let previous = nodes[id], previous !== row { previous.removeFromSupernode() }
        nodes[id] = row
        row.onHeightChanged = { [weak self] row in self?.heightChanged(row) }
        if let index = geometry.indices[id] {
            row.frame = geometry.frame(at: index, width: size.width)
            if currentVisibleRange().contains(index) {
                contentNode.addSubnode(row)
                attached[id] = row
            }
            // Start Texture drawing ahead of visibility, without waiting for
            // rasterization or pretending an offscreen node is visible.
            row.layoutIfNeeded()
            row.recursivelyEnsureDisplaySynchronously(false)
        }
    }

    private func updateNodes() {
        guard !updatingNodes, size.width > 0, size.height > 0 else { return }
        updatingNodes = true
        defer { updatingNodes = false }
        // A normal scroll changes one bounds origin, not every row's frame.
        contentNode.bounds = CGRect(x: 0, y: offset, width: size.width, height: size.height)
        let visible = currentVisibleRange()
        if hierarchyDirty || visibleRange != visible {
            for (id, row) in attached {
                if let index = geometry.indices[id], visible.contains(index), nodes[id] === row { continue }
                row.removeFromSupernode()
                attached.removeValue(forKey: id)
            }
            for index in visible {
                let id = geometry.ids[index]
                guard let row = nodes[id] else { continue }
                if hierarchyDirty { row.frame = geometry.frame(at: index, width: size.width) }
                if attached[id] == nil {
                    // A retained, detached row may have moved after insertion.
                    row.frame = geometry.frame(at: index, width: size.width)
                    contentNode.addSubnode(row)
                    attached[id] = row
                }
            }
            visibleRange = visible
            hierarchyDirty = false
        }

        // A width change is followed by a newly measured snapshot. Do not
        // request rows against its predecessor while that snapshot is pending.
        guard snapshotWidth == size.width else { return }
        let preload = preloadRange()
        guard requestedRange != preload else { return }
        requestedRange = preload
        let retained = retentionRange()
        for id in nodes.keys {
            if let index = geometry.indices[id], retained.contains(index) { continue }
            nodes.removeValue(forKey: id)?.removeFromSupernode()
        }
        for id in ready.keys {
            if let index = geometry.indices[id], preload.contains(index) { continue }
            ready.removeValue(forKey: id)
        }
        scheduleInstallation()
        let missing = prioritized(preload).compactMap { index -> ChatPlaygroundItem? in
            let item = items[index]
            return nodes[item.id] == nil && ready[item.id] == nil && !pending.contains(item.id) ? item : nil
        }
        guard !missing.isEmpty else { return }
        pending.formUnion(missing.map(\.id))
        let expectedRevision = revision
        let expectedWidth = size.width
        preparation.nodes(for: missing, width: expectedWidth) { [weak self] prepared in
            guard let self, self.revision == expectedRevision, self.size.width == expectedWidth else { return }
            let preload = self.preloadRange()
            for (id, row) in prepared {
                self.pending.remove(id)
                if let index = self.geometry.indices[id], preload.contains(index), self.nodes[id] == nil {
                    self.ready[id] = row
                }
            }
            self.scheduleInstallation()
        }
    }

    private func prioritized(_ range: Range<Int>) -> [Int] {
        let center = offset + size.height / 2
        return range.sorted {
            // Distance to the row's interval, rather than its center, keeps
            // a very tall visible message ahead of short offscreen rows.
            func distance(_ index: Int) -> CGFloat {
                max(0, max(geometry.origins[index] - center,
                           center - geometry.origins[index] - geometry.heights[index]))
            }
            let lhs = distance($0), rhs = distance($1)
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    private func scheduleInstallation() {
        guard !ready.isEmpty, installationLink == nil else { return }
        installationLink = DisplayLinkDriver.shared.subscribe(rate: .max) { [weak self] frame in
            self?.installReadyNodes(frame: frame)
        }
    }

    private func installReadyNodes(frame: DisplayLinkDriver.Frame) {
        let start = CACurrentMediaTime()
        // A count cap handles cheap rows; elapsed time handles expensive ones.
        // One row cannot be interrupted, so this is a soft installation budget.
        let budget = min(0.002, frame.duration > 0 ? frame.duration * 0.2 : 0.002)
        var installed = 0
        for index in prioritized(preloadRange()) {
            let id = geometry.ids[index]
            guard let row = ready.removeValue(forKey: id) else { continue }
            install(row, id: id)
            installed += 1
            if installed == 4 || CACurrentMediaTime() - start >= budget { break }
        }
        if ready.isEmpty {
            installationLink?.invalidate()
            installationLink = nil
        }
        if installed > 0 {
            hierarchyDirty = true
            updateNodes()
            onScroll?()
        }
    }

    private func heightChanged(_ row: ChatPlaygroundRowNode) {
        guard nodes[row.itemID] === row, let index = geometry.indices[row.itemID] else { return }
        let height = max(0.01, row.calculatedSize.height)
        guard abs(geometry.heights[index] - height) > 0.5 else { return }
        var heights = geometry.heights
        heights[index] = height
        let next = ChatListGeometry(ids: geometry.ids, heights: heights)
        offset = next.offset(
            replacing: geometry, current: offset, viewport: size.height,
            insets: insets, destination: .preserve
        )
        geometry = next
        hierarchyDirty = true
        requestedRange = nil
        updateMotor()
        updateNodes()
        onScroll?()
    }

    private func updateMotor() {
        guard size.height > 0 else { return }
        let limits = geometry.limits(viewport: size.height, insets: insets)
        let range = limits.upperBound - limits.lowerBound
        let base: CGFloat
        let span: CGFloat
        if range <= motorSpan {
            base = limits.lowerBound
            span = range
        } else {
            span = motorSpan
            if offset < limits.lowerBound + motorSpan / 4 {
                base = limits.lowerBound
            } else if offset > limits.upperBound - motorSpan / 4 {
                base = limits.upperBound - motorSpan
            } else if motorBase >= limits.lowerBound,
                      motorBase + motorSpan <= limits.upperBound,
                      offset - motorBase > motorSpan / 4,
                      offset - motorBase < motorSpan * 3 / 4 {
                base = motorBase
            } else {
                base = offset - motorSpan / 2
            }
        }
        let contentSize = CGSize(width: size.width, height: size.height + span)
        let motorOffset = CGPoint(x: 0, y: offset - base)
        ignoringMotion = true
        motorBase = base
        if scrollView.contentSize != contentSize { scrollView.contentSize = contentSize }
        // The property setter keeps native drag/deceleration running.
        // Ignore arithmetic noise when converting between logical and native
        // coordinates; normal scroll callbacks must not write the offset back.
        if abs(scrollView.contentOffset.y - motorOffset.y) > 0.0001 {
            scrollView.contentOffset = motorOffset
        }
        lastMotorOffset = scrollView.contentOffset.y
        ignoringMotion = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !ignoringMotion else { return }
        offset += scrollView.contentOffset.y - lastMotorOffset
        lastMotorOffset = scrollView.contentOffset.y
        updateMotor()
        updateNodes()
        onScroll?()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onMotionChanged?(.dragging) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onMotionChanged?(decelerate ? .decelerating : .idle)
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { onMotionChanged?(.idle) }
}
#endif
