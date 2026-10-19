// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

/// Fixed adaptive row heights give a sparse, month-prefix layout. Neither
/// measuring nodes nor scrolling visits the complete attachment catalog.
struct RoomProfileListGeometry {
    enum Element: Hashable { case header(Int), item(Int), footer }
    struct Month {
        let first: Int
        let count: Int
        let y: CGFloat
    }
    let months: [Month]
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let bodyHeight: CGFloat
    let count: Int
    private let stride: CGFloat

    init(months source: [RoomMediaMonth], rowHeight: CGFloat, headerHeight: CGFloat) {
        self.rowHeight = rowHeight; self.headerHeight = headerHeight
        stride = rowHeight + 2
        var months: [Month] = []
        var first = 0
        var y: CGFloat = 0
        for month in source where month.count > 0 {
            months.append(Month(first: first, count: month.count, y: y))
            first += month.count
            y += headerHeight + 2 + CGFloat(month.count) * stride
        }
        self.months = months; count = first; bodyHeight = max(0, y - 2)
    }

    private func month(atY y: CGFloat) -> Int {
        var lower = 0, upper = months.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if months[middle].y <= y { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    func frame(at index: Int, width: CGFloat) -> CGRect? {
        guard index >= 0, index < count else { return nil }
        var lower = 0, upper = months.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if months[middle].first <= index { lower = middle + 1 } else { upper = middle }
        }
        let month = months[max(0, lower - 1)]
        return CGRect(x: 0, y: month.y + headerHeight + 2 + CGFloat(index - month.first) * stride,
            width: width, height: rowHeight)
    }

    func elements(in rect: CGRect, width: CGFloat, footerHeight: CGFloat) -> [(Element, CGRect)] {
        var result: [(Element, CGRect)] = []
        if !months.isEmpty {
            var position = month(atY: rect.minY)
            while position < months.count, months[position].y < rect.maxY {
                let month = months[position]
                let header = CGRect(x: 0, y: month.y, width: width, height: headerHeight)
                if header.intersects(rect) { result.append((.header(position), header)) }
                let start = month.y + headerHeight + 2
                let lower = max(0, min(month.count, Int(floor((rect.minY - start) / stride))))
                let upper = max(lower, min(month.count, Int(ceil((rect.maxY - start) / stride))))
                for index in lower..<upper {
                    result.append((.item(month.first + index),
                        CGRect(x: 0, y: start + CGFloat(index) * stride, width: width, height: rowHeight)))
                }
                position += 1
            }
        }
        let footer = CGRect(x: 0, y: bodyHeight, width: width, height: footerHeight)
        if footerHeight > 0, footer.intersects(rect) { result.append((.footer, footer)) }
        return result
    }

    func index(atY y: CGFloat) -> Int? {
        guard !months.isEmpty else { return nil }
        let month = months[month(atY: y)]
        let offset = max(0, min(month.count - 1, Int(floor((y - month.y - headerHeight - 2) / stride))))
        return month.first + offset
    }
}

/// Native vertical physics with only viewport Texture nodes. A playing row
/// is one extra retained node, positioned from its natural catalog index.
@MainActor
final class RoomProfilePagedList {
    enum Content: Equatable {
        case row(RoomProfileRow)
        case attachment(AttachmentItem)

        var row: RoomProfileRow {
            switch self {
            case .row(let row): return row
            case .attachment(let item):
                return RoomProfileRow.rows(groups: [AttachmentMonthGroup(id: "", title: "", items: [item])]).last!
            }
        }
    }
    let node = ASDisplayNode(viewBlock: { RoomProfileMediaScrollView() })
    var view: UIView { node.view }
    var scrollView: UIScrollView { node.view as! UIScrollView }
    let catalog: RoomMediaCatalog
    private(set) var snapshot = RoomMediaSnapshot(revision: -1, months: [])
    private(set) var geometry = RoomProfileListGeometry(months: [], rowHeight: 76, headerHeight: 40)
    var onRestoreDepth: ((CGFloat) -> Void)?
    var onContentChanged: (() -> Void)?
    var onDockedHeight: ((CGFloat?) -> Void)?
    var onLoad: (() -> Void)?
    var restorationAnchor: RoomProfileAnchor?
    private let makeCell: (Content) -> ASCellNodeBlock
    private let cellQueue = DispatchQueue(label: "zyna.profile.list-cells", qos: .userInitiated)
    private struct Binding {
        let node: ASCellNode
        let content: Content?
        var index: Int?
        var visible: Bool
        var dockEdge: RoomProfileListAttributes.DockEdge?
    }
    private final class Build: @unchecked Sendable {
        let content: Content
        let size: CGSize
        let cancelled = Atomic(false)
        init(content: Content, size: CGSize) { self.content = content; self.size = size }
    }
    private var cells: [String: Binding] = [:]
    private var builds: [String: Build] = [:]
    private var footer = RoomProfileRow(id: "footer", title: "", detail: nil, item: nil, isHeader: false, isAction: false)
    private var visibleInsets = UIEdgeInsets.zero
    private var playingID: String?
    private var playingIndex: Int?
    private var updateTask: Task<Void, Never>?
    private var playerTask: Task<Void, Never>?
    private var pendingSnapshot: RoomMediaSnapshot?
    private var acceptanceError: Error?
    private var generation = 0
    private var installed = false
    private var stopped = false
    private var rendering = false
    private(set) var isAdjusting = false
    var isActive = false {
        didSet {
            guard oldValue != isActive, installed, !stopped else { return }
            if isActive {
                catalog.start()
                if catalog.snapshot.revision >= 0, catalog.snapshot != snapshot || acceptanceError != nil {
                    accept(catalog.snapshot)
                }
            } else { catalog.suspend() }
            render()
        }
    }
    var isLocked = false {
        didSet {
            guard oldValue != isLocked else { return }
            if isLocked {
                builds.values.forEach { $0.cancelled.wrappedValue = true }
                builds.removeAll()
                return
            }
            resumeUpdates()
        }
    }
    // Returning to the top defers catalog replacement but still virtualizes
    // every animated viewport. A lifted context row also freezes rendering.
    var isScrollingToBeginning = false {
        didSet { if oldValue && !isScrollingToBeginning { resumeUpdates() } }
    }
    private var defersReplacement: Bool { isLocked || isScrollingToBeginning }
    var renderedNodeCount: Int { cells.count }
    var error: Error? { acceptanceError ?? catalog.error }

    init(catalog: RoomMediaCatalog, makeCell: @escaping (Content) -> ASCellNodeBlock) {
        self.catalog = catalog; self.makeCell = makeCell
        node.backgroundColor = .appBG
        catalog.onSnapshot = { [weak self] in self?.accept($0) }
        catalog.onItemsChanged = { [weak self] in
            guard let self else { return }
            if self.defersReplacement { self.onContentChanged?(); return }
            let resized = self.updateSize()
            self.render()
            if !resized { self.onContentChanged?() }
        }
    }

    deinit {
        updateTask?.cancel(); playerTask?.cancel()
        builds.values.forEach { $0.cancelled.wrappedValue = true }
    }

    private func resumeUpdates() {
        guard !defersReplacement else { return }
        updateSize()
        if let pendingSnapshot { self.pendingSnapshot = nil; accept(pendingSnapshot) }
        else { render() }
    }

    func install() {
        guard !installed, !stopped else { return }
        installed = true
        if isActive { catalog.start() }
        else {
            // A neighboring preview needs one read, not a live subscription.
            // Defer until the controller has assigned initial activity.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, !self.isActive, self.catalog.snapshot.revision < 0 else { return }
                self.catalog.refresh()
            }
        }
        if catalog.snapshot.revision >= 0 { accept(catalog.snapshot) }
    }

    func stop() {
        stopped = true
        generation += 1
        updateTask?.cancel(); updateTask = nil
        playerTask?.cancel(); playerTask = nil
        builds.values.forEach { $0.cancelled.wrappedValue = true }; builds.removeAll()
        catalog.stop()
    }

    func layout(rowHeight: CGFloat, headerHeight: CGFloat, visibleInsets: UIEdgeInsets) {
        self.visibleInsets = visibleInsets
        if rowHeight != geometry.rowHeight || headerHeight != geometry.headerHeight {
            geometry = RoomProfileListGeometry(months: snapshot.months, rowHeight: rowHeight, headerHeight: headerHeight)
            if updateTask != nil {
                generation += 1; updateTask?.cancel(); updateTask = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.catalog.snapshot.revision >= 0 else { return }
                    self.accept(self.catalog.snapshot)
                }
            }
        }
        updateSize()
        render()
    }

    func update(_ footer: RoomProfileRow) {
        guard self.footer != footer else { return }
        self.footer = footer
        guard !defersReplacement else { return }
        updateSize(); render()
    }

    func refreshTypography() {
        for key in Array(cells.keys) { remove(key) }
        render()
    }

    @objc private func tapFooter() {
        guard isActive, !isLocked, displayedFooter.isAction else { return }
        if error != nil { retry() }
        else { onLoad?() }
    }

    func retry() {
        acceptanceError = nil
        catalog.retry()
        if catalog.snapshot.revision >= 0 { accept(catalog.snapshot) }
    }

    private var displayedFooter: RoomProfileRow {
        if let error {
            return RoomProfileRow(id: "footer", title: String(localized: "Try Again"),
                detail: error.localizedDescription, item: nil, isHeader: false, isAction: true)
        }
        if snapshot.revision < 0 {
            return RoomProfileRow(id: "footer", title: String(localized: "Loading"),
                detail: nil, item: nil, isHeader: false, isAction: false)
        }
        return footer
    }

    private var footerHeight: CGFloat {
        let row = displayedFooter
        return row.title.isEmpty && row.detail == nil ? 0 : UIFontMetrics.default.scaledValue(for: 104)
    }

    @discardableResult
    private func updateSize() -> Bool {
        let size = CGSize(width: scrollView.bounds.width, height: geometry.bodyHeight + footerHeight)
        guard scrollView.contentSize != size else { return false }
        let adjusting = isAdjusting
        isAdjusting = true
        defer { isAdjusting = adjusting }
        let offset = scrollView.contentOffset
        scrollView.contentSize = size
        // Footer/error changes also affect short-content padding and near-end
        // state. Notify the page while scroll corrections are still guarded.
        onContentChanged?()
        // UIKit may clamp against the old bottom inset before the page pads
        // short content. Restore the viewport after both values are current,
        // and cancel queued corrections while native scrolling is idle.
        let moving = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        let minimum = -scrollView.contentInset.top
        let maximum = max(minimum, size.height + scrollView.contentInset.bottom - scrollView.bounds.height)
        let target = CGPoint(x: offset.x, y: moving ? offset.y : min(maximum, max(minimum, offset.y)))
        if moving {
            if scrollView.contentOffset != target { scrollView.contentOffset = target }
        } else { scrollView.setContentOffset(target, animated: false) }
        if !moving, target.y != offset.y, snapshot.revision >= 0, restorationAnchor == nil {
            // Persist a genuine clamp, including for a hidden page. Initial
            // loading geometry must not overwrite a pending restored anchor.
            onRestoreDepth?(max(0, target.y + visibleInsets.top))
        }
        return true
    }

    private var viewport: CGRect { scrollView.bounds.inset(by: visibleInsets) }

    func captureAnchor() -> RoomProfileAnchor? {
        let top = viewport.minY
        guard top > 0, let index = geometry.index(atY: top),
              let id = snapshot.order.id(at: index), let frame = geometry.frame(at: index, width: view.bounds.width) else { return nil }
        return RoomProfileAnchor(id: id, previousIndex: index, offset: top - frame.minY)
    }

    func restore(_ anchor: RoomProfileAnchor) {
        guard let frame = geometry.frame(at: anchor.previousIndex, width: view.bounds.width) else { return }
        let maximum = max(0, scrollView.contentSize.height + scrollView.contentInset.bottom
            - scrollView.bounds.height + visibleInsets.top)
        onRestoreDepth?(min(maximum, max(0, frame.minY + anchor.offset)))
    }

    private func accept(_ next: RoomMediaSnapshot) {
        guard !stopped, next.revision >= snapshot.revision else { return }
        generation += 1
        updateTask?.cancel()
        updateTask = nil
        guard !defersReplacement else { pendingSnapshot = next; return }
        let anchor = captureAnchor() ?? restorationAnchor
        let initialTop = viewport.minY
        let unchangedOrder = next.orderRevision == snapshot.orderRevision
        let generation = generation
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let restored: Int?
                if let anchor {
                    restored = unchangedOrder ? anchor.previousIndex : try await self.catalog.index(of: anchor.id, in: next)
                } else { restored = nil }
                let index = max(0, min(max(0, next.count - 1), restored ?? anchor?.previousIndex ?? 0))
                let visibleCount = max(1, Int(ceil(self.scrollView.bounds.height / self.geometry.rowHeight)))
                try await self.catalog.prepare(max(0, index - 6)..<min(next.count, index + visibleCount + 6), in: next)
                // Playback can change while anchor/page reads are suspended.
                // Only commit an index for the current playback identity.
                var playerIndex: Int?
                var playerID = self.playingID
                repeat {
                    playerID = self.playingID
                    playerIndex = unchangedOrder ? self.playingIndex : nil
                    if let id = playerID, playerIndex == nil { playerIndex = try await self.catalog.index(of: id, in: next) }
                } while playerID != self.playingID && !Task.isCancelled
                guard !Task.isCancelled, generation == self.generation else { return }
                if self.defersReplacement { self.pendingSnapshot = next; return }
                let movement = self.viewport.minY - initialTop
                self.isAdjusting = true
                self.acceptanceError = nil
                self.snapshot = next; self.playingIndex = playerIndex
                self.geometry = RoomProfileListGeometry(months: next.months,
                    rowHeight: self.geometry.rowHeight, headerHeight: self.geometry.headerHeight)
                let resized = self.updateSize()
                if let anchor {
                    if next.count == 0 { self.onRestoreDepth?(0) }
                    else { self.restore(RoomProfileAnchor(id: anchor.id, previousIndex: index, offset: anchor.offset + movement)) }
                    self.restorationAnchor = nil
                }
                self.render()
                if !resized { self.onContentChanged?() }
                self.updateTask = nil
                self.isAdjusting = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                self.updateTask = nil
                if case RoomMediaDatabase.CatalogError.stale = error { return }
                self.acceptanceError = error
                let resized = self.updateSize()
                self.render()
                if !resized { self.onContentChanged?() }
            }
        }
    }

    func setPlaying(_ id: String?) {
        guard id != playingID else { return }
        playingID = id
        // A visible row already has authoritative geometry. Retain it
        // synchronously before a scroll can evict it during the database read.
        playingIndex = id.flatMap { cells[$0]?.index }
        playerTask?.cancel()
        guard let id, playingIndex == nil else { render(); return }
        let snapshot = snapshot
        playerTask = Task { [weak self] in
            guard let self else { return }
            let index = try? await self.catalog.index(of: id, in: snapshot)
            guard !Task.isCancelled, self.playingID == id, self.snapshot.revision == snapshot.revision else { return }
            self.playingIndex = index
            self.render()
        }
    }

    func contains(_ id: String) -> Bool { cells[id] != nil }

    func render() {
        guard !stopped, !rendering, !isLocked, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
        rendering = true
        defer { rendering = false }
        let width = scrollView.bounds.width
        let area = viewport
        let buffer = area.insetBy(dx: 0, dy: -geometry.rowHeight * 6)
        var elements = geometry.elements(in: buffer, width: width, footerHeight: footerHeight)
        if let playingIndex, !elements.contains(where: { $0.0 == .item(playingIndex) }),
           let frame = geometry.frame(at: playingIndex, width: width) { elements.append((.item(playingIndex), frame)) }
        let indices = elements.compactMap { element, _ -> Int? in
            if case .item(let index) = element, index != playingIndex { return index }
            return nil
        }
        let range: Range<Int>
        if let lower = indices.min(), let upper = indices.max() { range = lower..<(upper + 1) }
        else if let playingIndex { range = playingIndex..<(playingIndex + 1) }
        else { range = 0..<min(1, snapshot.count) }
        if isActive, snapshot.revision == catalog.snapshot.revision { catalog.ensure(range, additionalIndex: playingIndex) }
        var retained = Set<String>()
        var dockedHeight: CGFloat?
        for (element, naturalFrame) in elements {
            let key: String
            let content: Content?
            var frame = naturalFrame
            var dockEdge = RoomProfileListAttributes.DockEdge.none
            switch element {
            case .header(let index):
                let month = snapshot.months[index]
                key = "month:\(month.id)"
                content = .row(RoomProfileRow(id: key, title: month.title, detail: nil, item: nil, isHeader: true, isAction: false))
            case .item(let index):
                guard let id = snapshot.order.id(at: index) else { continue }
                key = id
                if snapshot.revision == catalog.snapshot.revision, let item = catalog.item(at: index) {
                    content = .attachment(item)
                } else { content = cells[key]?.content }
                if index == playingIndex {
                    frame = RoomProfileListLayout.pinnedFrame(naturalFrame, in: area)
                    dockEdge = frame.minY > naturalFrame.minY ? .top : (frame.minY < naturalFrame.minY ? .bottom : .none)
                    if dockEdge == .bottom { dockedHeight = frame.height }
                }
            case .footer:
                key = "footer"; content = .row(displayedFooter)
            }
            retained.insert(key)
            if cells[key] == nil {
                let cell = ASCellNode()
                cell.backgroundColor = .secondarySystemFill; cell.isAccessibilityElement = false
                cell.frame = frame; node.addSubnode(cell)
                cells[key] = Binding(node: cell, content: nil, index: nil, visible: false, dockEdge: nil)
            }
            if let content, cells[key]?.content != content {
                build(key: key, content: content, size: frame.size)
            } else if let build = builds.removeValue(forKey: key) {
                build.cancelled.wrappedValue = true
            }
            guard var binding = cells[key] else { continue }
            if case .item(let index) = element { binding.index = index }
            if binding.node.frame.size != frame.size {
                _ = binding.node.layoutThatFits(ASSizeRange(min: frame.size, max: frame.size))
                binding.node.frame = frame; binding.node.setNeedsLayout(); binding.node.layoutIfNeeded()
            } else { binding.node.frame = frame }
            if let cell = binding.node as? ListContextMenuCellNode {
                if binding.dockEdge != dockEdge, let changed = cell.onLayoutAttributesChanged {
                    let attributes = RoomProfileListAttributes(forCellWith: IndexPath(item: binding.index ?? 0, section: 0))
                    attributes.frame = frame; attributes.dockEdge = dockEdge
                    changed(attributes)
                }
                binding.dockEdge = dockEdge
                if case .item(let index) = element, index == playingIndex { node.view.bringSubviewToFront(cell.view) }
            }
            let visible = isActive && frame.intersects(area)
            if binding.visible != visible {
                (binding.node as? ListContextMenuCellNode)?.onViewportVisibilityChanged?(visible)
                binding.visible = visible
            }
            cells[key] = binding
        }
        for key in Array(cells.keys) where !retained.contains(key) { remove(key) }
        onDockedHeight?(dockedHeight)
    }

    private func remove(_ key: String) {
        builds.removeValue(forKey: key)?.cancelled.wrappedValue = true
        guard let binding = cells.removeValue(forKey: key) else { return }
        (binding.node as? ListContextMenuCellNode)?.onViewportVisibilityChanged?(false)
        binding.node.removeFromSupernode()
    }

    /// Texture factories and measurement run on a serial worker, just as
    /// ASCollectionNode's node blocks do. Stale viewport requests are cancelled
    /// before construction; only still-wanted cells are mounted on main.
    private func build(key: String, content: Content, size: CGSize) {
        if let current = builds[key], current.content == content, current.size == size { return }
        builds.removeValue(forKey: key)?.cancelled.wrappedValue = true
        let request = Build(content: content, size: size)
        builds[key] = request
        let block = makeCell(content)
        cellQueue.async { [weak self] in
            guard !request.cancelled.wrappedValue else { return }
            let cell = block()
            _ = cell.layoutThatFits(ASSizeRange(min: size, max: size))
            guard !request.cancelled.wrappedValue else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.builds[key] === request, !self.isLocked,
                          let old = self.cells[key] else { return }
                    self.builds[key] = nil
                    (old.node as? ListContextMenuCellNode)?.onViewportVisibilityChanged?(false)
                    old.node.removeFromSupernode()
                    cell.frame = old.node.frame
                    self.node.addSubnode(cell); cell.layoutIfNeeded()
                    if key == "footer" {
                        cell.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapFooter)))
                    }
                    self.cells[key] = Binding(node: cell, content: content, index: old.index, visible: false, dockEdge: nil)
                    self.render()
                }
            }
        }
    }
}
