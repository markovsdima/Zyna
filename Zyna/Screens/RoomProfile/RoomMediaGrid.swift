// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

private final class RoomMediaDisplayLinkTarget: NSObject {
    var tick: ((CADisplayLink) -> Void)?
    @objc func step(_ link: CADisplayLink) { tick?(link) }
}

private final class RoomMediaAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

/// A virtualized media surface. UIKit owns vertical physics; the bounded
/// layer pool owns pixels. No Texture cell exists for an offscreen record.
@MainActor
final class RoomMediaGrid: NSObject, RoomProfileContentPage, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let node = ASDisplayNode(viewBlock: { RoomProfileMediaScrollView() })
    let catalog: RoomMediaCatalog
    var view: UIView { node.view }
    var scrollView: UIScrollView { node.view as! UIScrollView }
    var inset: CGFloat { headerHeight + tabsHeight }
    var normalizedOffset: CGFloat { scrollView.contentOffset.y + inset }
    private(set) var isAdjusting = false
    private var isHandlingScroll = false
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive {
                finishZoomImmediately()
                stopScrolling()
            }
            updateNearEnd()
        }
    }
    var headerHeight: CGFloat = 220
    var avatarExpansionHeight: CGFloat = 0
    var tabsHeight: CGFloat = 48
    var collapse: CGFloat = 0
    var restorationAnchor: RoomProfileAnchor?
    var forceLoadIds: Set<String> = []
    var fullFileThreshold = AttachmentThumbnailPlan.defaultFullFileThreshold
    var onScroll: (() -> Void)?
    var onBeginDragging: (() -> Void)?
    var onWillEndDragging: ((CGPoint, UnsafeMutablePointer<CGPoint>) -> Void)?
    var onEndDragging: (() -> Void)?
    var onSelect: ((AttachmentItem, UIImage?, CGRect) -> Void)?
    var onShowInChat: ((AttachmentItem) -> Void)?
    var onLoad: (() -> Void)?
    var onRequestImage: ((AttachmentItem) -> Void)?
    var onAnchorRestored: ((CGFloat) -> Void)?
    var onNearEnd: ((Bool) -> Void)?
    var onContextInteractionChanged: ((Bool) -> Void)?
    var onCountChanged: ((Int) -> Void)?
    var onColumnsChanged: ((Int) -> Void)?
    private(set) var columns: Int
    private(set) var geometry: RoomMediaGeometry?
    private var layouts: [Int: RoomMediaGeometry] = [:]
    private var appliedSnapshot = RoomMediaSnapshot(revision: -2, months: [])
    private var pendingSnapshot: RoomMediaSnapshot?
    private var preparation: Task<Void, Never>?
    private var preparationID = 0
    private var preparationError: Error?
    private var tiles: [Int: RoomMediaTileLayer] = [:]
    private var spareTiles: [RoomMediaTileLayer] = []
    private var monthNodes: [String: ASTextNode] = [:]
    private var visibleRange: Range<Int> = 0..<0
    private var demandRange: Range<Int> = 0..<0
    private var needsRender = true
    private var footer = RoomProfileRow(id: "footer", title: "", detail: nil, item: nil, isHeader: false, isAction: false)
    private var renderedFooter: String?
    private let footerNode = ASTextNode()
    private let zoomLabel = UILabel()
    private var bottomInset: CGFloat = 0
    private var nearEnd = false
    private var scrollingToBeginning = false
    var isScrollingToBeginning: Bool { scrollingToBeginning }
    private var menu: ListContextMenuController?
    private var menuIndex: Int?
    private var isLocked = false
    private var pinch: UIPinchGestureRecognizer?
    private var longPress: UILongPressGestureRecognizer?
    private var zoom: Zoom?
    private var zoomSurfaces: [Int: RoomMediaZoomSurface] = [:]
    private var zoomSourceRange: Range<Int>?
    private var animation: ZoomAnimation?
    private let linkTarget = RoomMediaDisplayLinkTarget()
    private var displayLink: CADisplayLink?
    private lazy var fpsBooster = ScrollFPSBooster(hostView: view)
    private var voiceOverObserver: NSObjectProtocol?

    private struct Zoom {
        let initialColumns: Int
        let anchorIndex: Int
        let unitY: CGFloat
        let screenY: CGFloat
        let horizontalEdge: CGFloat
        var density: CGFloat
    }
    private struct ZoomAnimation {
        let start: CFTimeInterval
        let density: CGFloat
        let destination: Int
    }

    init(catalog: RoomMediaCatalog, columns: Int = 3) {
        self.catalog = catalog
        self.columns = min(10, max(2, columns))
        super.init()
        catalog.onSnapshot = { [weak self] snapshot in self?.receive(snapshot) }
        catalog.onItemsChanged = { [weak self] in
            guard let self else { return }
            self.renderFooter()
            guard self.appliedSnapshot.revision == self.catalog.snapshot.revision else { return }
            if let zoom = self.zoom, self.animation == nil {
                self.renderZoom(density: zoom.density, refreshSources: true); return
            }
            self.render(force: true)
        }
    }

    deinit {
        preparation?.cancel(); displayLink?.invalidate()
        if let voiceOverObserver { NotificationCenter.default.removeObserver(voiceOverObserver) }
    }

    var renderedTileCount: Int { isZooming ? zoomSurfaces.values.reduce(0) { $0 + $1.tileCount } : tiles.count }
    var retainedTileCount: Int { tiles.count + zoomSurfaces.values.reduce(0) { $0 + $1.tileCount } }
    var isZooming: Bool { zoom != nil }
    func frameForItem(at index: Int) -> CGRect? { geometry?.frame(at: index) }
    func displayedFrame(at index: Int) -> CGRect? {
        if isZooming { return zoomPresentations(at: index).max { $0.opacity < $1.opacity }?.frame }
        return tiles[index]?.frame
    }
    func zoomPresentations(at index: Int) -> [(columns: Int, frame: CGRect, opacity: Float)] {
        zoomSurfaces.values.compactMap { surface in
            surface.frame(at: index, in: scrollView.layer).map { (surface.geometry.columns, $0, surface.node.layer.opacity) }
        }
    }
    func loadedItem(at index: Int) -> AttachmentItem? { tiles[index]?.item ?? catalog.item(at: index) }

    func install() {
        let scroll = scrollView
        scroll.backgroundColor = .appBG
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.scrollsToTop = false
        scroll.accessibilityIdentifier = "profile.media"
        scroll.isAccessibilityElement = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        hold.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        self.pinch = pinch; longPress = hold
        tap.require(toFail: hold)
        tap.require(toFail: pinch)
        // A pinch stays possible while one finger is down. Waiting for it
        // to fail would delay the menu until that finger lifts. Reject a
        // two-finger hold in the delegate instead.
        scroll.addGestureRecognizer(tap); scroll.addGestureRecognizer(hold); scroll.addGestureRecognizer(pinch)
        node.addSubnode(footerNode)
        footerNode.maximumNumberOfLines = 4
        footerNode.isAccessibilityElement = true
        footerNode.accessibilityTraits = .button
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        zoomLabel.textColor = .white
        zoomLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        zoomLabel.textAlignment = .center
        zoomLabel.layer.cornerRadius = 14
        zoomLabel.clipsToBounds = true
        zoomLabel.isHidden = true
        scroll.addSubview(zoomLabel)
        scroll.accessibilityCustomActions = zoomAccessibilityActions()
        voiceOverObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAccessibility() }
            }
        catalog.start()
        if catalog.snapshot.revision >= 0 { receive(catalog.snapshot) }
    }

    private func zoomAccessibilityActions() -> [UIAccessibilityCustomAction] {
        [
            UIAccessibilityCustomAction(name: String(localized: "Larger thumbnails", table: "RoomProfile")) { [weak self] _ in
                guard let self, self.columns > 2 else { return false }
                self.setColumns(self.columns - 1, animated: !UIAccessibility.isReduceMotionEnabled); return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Smaller thumbnails", table: "RoomProfile")) { [weak self] _ in
                guard let self, self.columns < 10 else { return false }
                self.setColumns(self.columns + 1, animated: !UIAccessibility.isReduceMotionEnabled); return true
            }
        ]
    }

    func layout(frame: CGRect, depth: CGFloat, bottomInset: CGFloat) {
        let resized = view.bounds.size != frame.size
        let anchor = captureAnchor() ?? restorationAnchor
        if resized { dismissContextMenu(); finishZoomImmediately(); stopScrollingToBeginning() }
        isAdjusting = true
        node.frame = frame
        self.bottomInset = bottomInset
        scrollView.contentInset.top = inset
        padContent()
        setPosition(depth: depth)
        isAdjusting = false
        if resized || geometry == nil { prepare(catalog.snapshot, anchor: anchor) }
        else { render() }
    }

    func setPosition(depth: CGFloat) {
        guard !isZooming else { return }
        let adjusting = isAdjusting; isAdjusting = true
        let y = collapse + max(0, depth) - inset
        if abs(scrollView.contentOffset.y - y) > 0.25 { scrollView.contentOffset.y = y }
        scrollView.verticalScrollIndicatorInsets.top = inset - collapse
        isAdjusting = adjusting
        if !isHandlingScroll { render() }
    }

    private func padContent() {
        scrollView.contentSize = CGSize(width: view.bounds.width, height: (geometry?.height ?? 0) + 104)
        scrollView.contentInset.bottom = max(bottomInset, view.bounds.height - tabsHeight - scrollView.contentSize.height)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: inset - collapse, left: 0, bottom: bottomInset, right: 0)
    }

    func captureAnchor() -> RoomProfileAnchor? {
        guard let geometry, normalizedOffset > headerHeight + 0.5 else { return nil }
        let top = scrollView.contentOffset.y + inset - collapse
        guard let index = geometry.index(at: CGPoint(x: 1, y: top), nearest: true),
              let id = appliedSnapshot.order.id(at: index), let frame = geometry.frame(at: index) else { return nil }
        return RoomProfileAnchor(id: id, previousIndex: index, offset: top - frame.minY)
    }

    private func receive(_ snapshot: RoomMediaSnapshot) {
        onCountChanged?(snapshot.count)
        guard !isLocked, !scrollingToBeginning else { pendingSnapshot = snapshot; return }
        prepare(snapshot, anchor: captureAnchor() ?? restorationAnchor)
    }

    private func prepare(_ snapshot: RoomMediaSnapshot, anchor: RoomProfileAnchor?) {
        guard view.bounds.width > 0, snapshot.revision >= 0 else { return }
        preparation?.cancel()
        preparationError = nil
        preparationID += 1
        let id = preparationID
        let width = view.bounds.width
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let height = UIFontMetrics.default.scaledValue(for: 40)
        let columns = columns
        let offset = scrollView.contentOffset.y
        let viewportHeight = view.bounds.height
        preparation = Task { [weak self, catalog] in
            let layouts = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: (2...10).map {
                    ($0, RoomMediaGeometry(months: snapshot.months, width: width, columns: $0, scale: scale, headerHeight: height))
                })
            }.value
            do {
                var index: Int?
                if let anchor { index = try await catalog.index(of: anchor.id, in: snapshot) ?? min(anchor.previousIndex, snapshot.count - 1) }
                guard let next = layouts[columns] else { return }
                let top = index.flatMap { next.frame(at: $0).map { $0.minY + (anchor?.offset ?? 0) } }
                    ?? max(0, offset)
                let range = next.range(in: CGRect(x: 0, y: max(0, top - viewportHeight * 0.25),
                    width: width, height: viewportHeight * 1.5))
                try await catalog.prepare(range, in: snapshot)
                guard !Task.isCancelled, let self, self.preparationID == id, !self.isLocked,
                      catalog.snapshot == snapshot else { return }
                // A moving viewport gets a fresh anchor before committing.
                if abs(self.scrollView.contentOffset.y - offset) > 1 {
                    self.prepare(snapshot, anchor: self.captureAnchor() ?? anchor); return
                }
                self.layouts = layouts; self.geometry = next; self.appliedSnapshot = snapshot
                self.preparation = nil
                self.isAdjusting = true
                self.padContent()
                if let index, let anchor, let frame = next.frame(at: index) {
                    let depth = max(0, frame.minY + anchor.offset)
                    self.setPosition(depth: min(depth, self.maximumDepth))
                    self.onAnchorRestored?(min(depth, self.maximumDepth))
                    self.restorationAnchor = nil
                } else if next.count == 0 {
                    self.setPosition(depth: 0)
                    self.onAnchorRestored?(0)
                    self.restorationAnchor = nil
                }
                self.isAdjusting = false
                self.render(force: true)
                self.updateNearEnd()
            } catch is CancellationError {
            } catch RoomMediaDatabase.CatalogError.stale {
            } catch {
                guard let self, self.preparationID == id else { return }
                self.preparation = nil
                self.preparationError = error
                self.renderFooter(); self.updateAccessibility()
            }
        }
    }

    private var maximumDepth: CGFloat {
        max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - view.bounds.height + tabsHeight)
    }

    func update(_ rows: [RoomProfileRow]) {
        if catalog.source == nil {
            var groups: [AttachmentMonthGroup] = []
            var items: [AttachmentItem] = []
            var header: RoomProfileRow?
            func flush() {
                if let header, !items.isEmpty { groups.append(.init(id: header.id, title: header.title, items: items)) }
                items.removeAll()
            }
            for row in rows {
                if row.isHeader { flush(); header = row }
                else if let item = row.item { items.append(item) }
            }
            flush()
            catalog.replace(groups: groups)
        }
        if let footer = rows.last, footer.item == nil, !footer.isHeader, self.footer != footer {
            self.footer = footer
            renderFooter()
        }
    }

    private func renderFooter() {
        let error = preparationError ?? catalog.error
        let title = error == nil ? footer.title : String(localized: "Try Again")
        let detail = error?.localizedDescription ?? footer.detail
        let key = [title, detail].compactMap { $0 }.joined(separator: "\n")
        if renderedFooter != key {
            renderedFooter = key
            footerNode.attributedText = footerText(title, detail: detail)
            footerNode.accessibilityLabel = key
        }
        footerNode.frame = CGRect(x: 16, y: geometry?.height ?? 0, width: max(1, view.bounds.width - 32), height: 104)
    }

    private func footerText(_ title: String, detail: String?) -> NSAttributedString {
        NSAttributedString(string: [title, detail].compactMap { $0 }.joined(separator: "\n"), attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.secondaryLabel
        ])
    }

    func refreshTypography() {
        monthNodes.values.forEach { $0.removeFromSupernode() }; monthNodes.removeAll()
        renderedFooter = nil
        prepare(catalog.snapshot, anchor: captureAnchor()); renderFooter()
    }
    func refreshImagePlans() { render(force: true) }

    private func render(force: Bool = false) {
        guard !isZooming, let geometry, geometry.width == view.bounds.width else { return }
        let bounds = scrollView.bounds
        let visible = geometry.range(in: bounds)
        let demand = geometry.range(in: bounds.insetBy(dx: 0, dy: -bounds.height * 0.25))
        guard force || needsRender || demand != demandRange || visible != visibleRange else { return }
        needsRender = false; demandRange = demand; visibleRange = visible
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updateTiles(indices: demand, visible: visible, frame: { geometry.frame(at: $0) }, load: true, rebind: force,
                    pixels: Self.pixelSize(for: geometry.side * (view.window?.screen.scale ?? UIScreen.main.scale)))
        renderMonths(geometry, groups: geometry.groups(in: bounds))
        renderFooter()
        CATransaction.commit()
        if appliedSnapshot.revision == catalog.snapshot.revision { catalog.ensure(demand) }
        updateAccessibility()
    }

    static func pixelSize(for side: CGFloat) -> Int { [128, 256, 512, 768].first { CGFloat($0) >= side } ?? 768 }

    private func updateTiles(indices: Range<Int>, visible: Range<Int>, frame: (Int) -> CGRect?, load: Bool, rebind: Bool, pixels: Int) {
        for index in Array(tiles.keys) where !indices.contains(index) && index != menuIndex {
            if let tile = tiles.removeValue(forKey: index) {
                tile.removeFromSuperlayer(); tile.reset()
                if spareTiles.count < 32 { spareTiles.append(tile) }
            }
        }
        func update(_ index: Int) {
            // The menu temporarily owns this live layer's geometry. Keep
            // it pinned in the pool, with its existing image request.
            guard index != menuIndex, let frame = frame(index) else { return }
            let tile: RoomMediaTileLayer
            if let existing = tiles[index] { tile = existing }
            else {
                tile = spareTiles.popLast() ?? RoomMediaTileLayer()
                tiles[index] = tile
                scrollView.layer.insertSublayer(tile, at: 0)
            }
            tile.frame = frame
            tile.isHidden = isZooming
            let item = catalog.item(at: index)
            // Old pixels remain stable while the replacement revision
            // is being prepared, rather than binding new ordinals early.
            if appliedSnapshot.revision == catalog.snapshot.revision {
                if rebind || tile.item?.id != item?.id || tile.item == nil {
                    tile.bind(item, pixels: pixels, threshold: fullFileThreshold,
                              force: item.map { forceLoadIds.contains($0.id) } ?? false, load: load)
                }
            }
            tile.onVisualChange = { [weak self] tile in
                guard let self, self.tiles[index] === tile else { return }
                self.zoomSurfaces.values.forEach { $0.updateImage(at: index, from: tile) }
            }
            zoomSurfaces.values.forEach { $0.updateImage(at: index, from: tile) }
        }
        // Visible fetches enter the shared demand queue before the buffer.
        for index in visible where indices.contains(index) { update(index) }
        for index in indices where !visible.contains(index) { update(index) }
    }

    private func renderMonths(_ geometry: RoomMediaGeometry, groups: ArraySlice<RoomMediaGeometry.Group>) {
        let ids = Set(groups.map { $0.month.id })
        for id in Array(monthNodes.keys) where !ids.contains(id) { monthNodes.removeValue(forKey: id)?.removeFromSupernode() }
        for group in groups {
            let text: ASTextNode
            if let existing = monthNodes[group.month.id] { text = existing }
            else {
                text = ASTextNode()
                text.maximumNumberOfLines = 1
                text.isAccessibilityElement = true
                text.accessibilityTraits = .header
                monthNodes[group.month.id] = text
                node.addSubnode(text)
            }
            if text.attributedText?.string != group.month.title {
                text.attributedText = NSAttributedString(string: group.month.title, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.label
                ])
            }
            text.frame = CGRect(x: 16, y: group.top + 10, width: max(1, geometry.width - 32), height: geometry.headerHeight - 10)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjusting, !isZooming else { return }
        // Header dragging may correct the offset; render that final position
        // once instead of also rendering inside the nested setPosition call.
        isHandlingScroll = true
        defer { isHandlingScroll = false }
        onScroll?(); render(); updateNearEnd()
    }
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
        scrollingToBeginning = false; onScroll?(); flushPending()
    }
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { false }

    func scrollToBeginning(animated: Bool) {
        guard !isLocked else { return }
        let target = CGPoint(x: 0, y: avatarExpansionHeight - inset)
        scrollingToBeginning = animated && abs(scrollView.contentOffset.y - target.y) > 0.25
        if scrollingToBeginning && isActive { fpsBooster.start() } else { fpsBooster.stop() }
        scrollView.setContentOffset(target, animated: scrollingToBeginning)
        if !scrollingToBeginning { onScroll?(); render(); flushPending() }
    }
    func stopScrollingToBeginning() {
        guard scrollingToBeginning else { return }
        scrollingToBeginning = false
        fpsBooster.stop()
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        onScroll?(); flushPending()
    }
    func stopScrolling() {
        stopScrollingToBeginning()
        fpsBooster.stop()
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
    }
    func updateNearEnd() {
        let near = isActive && !isZooming && scrollView.contentOffset.y + view.bounds.height > scrollView.contentSize.height - 300
        guard near != nearEnd else { return }
        nearEnd = near; onNearEnd?(near)
    }

    private func lock(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked { fpsBooster.stop() }
        scrollView.isScrollEnabled = !locked
        onContextInteractionChanged?(locked)
        if !locked { flushPending() }
    }
    private func flushPending() {
        guard !isLocked, !scrollingToBeginning else { return }
        if let snapshot = pendingSnapshot { pendingSnapshot = nil; receive(snapshot) }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard !isLocked else { return }
        let point = gesture.location(in: scrollView)
        if let index = geometry?.index(at: point) { activate(index) }
        else if point.y >= (geometry?.height ?? 0) { activateFooter() }
    }

    private func activateFooter() {
        guard !isLocked else { return }
        catalog.retry()
        if preparationError != nil || appliedSnapshot.revision != catalog.snapshot.revision { receive(catalog.snapshot) }
        if footer.isAction { onLoad?() }
    }

    func activate(_ index: Int) {
        guard isActive, !isLocked, let tile = tiles[index], let item = tile.item else { return }
        let plan = AttachmentThumbnailPlan.make(for: item, tilePixelSize: Self.pixelSize(for: tile.bounds.width * UIScreen.main.scale),
                                               fullFileThreshold: fullFileThreshold, forceLoad: forceLoadIds.contains(item.id))
        if !tile.isReady, plan.isTapToLoad { onRequestImage?(item); return }
        if tile.failed { tile.retry(); render(force: true); return }
        onSelect?(item, tile.image, scrollView.convert(tile.frame, to: nil))
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let index = geometry?.index(at: gesture.location(in: scrollView)) else { return }
            presentMenu(at: index)
        case .changed: menu?.trackFinger(at: gesture.location(in: nil))
        case .ended, .cancelled: menu?.releaseFinger(at: gesture.location(in: nil))
        default: break
        }
    }

    func presentMenu(at index: Int) {
        guard isActive, !isLocked, let tile = tiles[index], let item = tile.item,
              let window = view.window, window.windowScene != nil else { return }
        stopScrollingToBeginning()
        let sourceFrame = tile.frame
        let frame = scrollView.convert(sourceFrame, to: window)
        let preview = ASDisplayNode()
        preview.frame = CGRect(origin: .zero, size: tile.bounds.size)
        let menu = ListContextMenuController(contentNode: preview, sourceFrame: frame,
            anchorPoint: CGPoint(x: frame.midX, y: frame.midY), actions: [
                ContextMenuAction(title: String(localized: "Show in Chat", table: "RoomProfile"),
                    image: UIImage(systemName: "bubble.left")) { [weak self] in self?.onShowInChat?(item) }
            ])
        menu.onDismissComplete = { [weak self, weak tile] in
            guard let self, let tile else { return }
            // Return the same rendered layer before the overlay disappears.
            // No image repaint or implicit fade may expose a blank frame.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.scrollView.layer.insertSublayer(tile, at: 0)
            tile.frame = self.geometry?.frame(at: index) ?? sourceFrame
            CATransaction.commit()
            self.menu = nil; self.menuIndex = nil; self.lock(false); self.render(force: true)
        }
        self.menu = menu; menuIndex = index
        lock(true)
        // Lift the live pixels and badges, as file cells lift their content.
        // Creating an ASImageNode here would wait for its first async paint.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.layer.addSublayer(tile)
        tile.frame = preview.bounds
        CATransaction.commit()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        menu.show(in: window)
    }
    func dismissContextMenu() { menu?.dismiss(animated: false); finishZoomImmediately() }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isActive, !isLocked, (geometry?.count ?? 0) > 0 else { return false }
        if gestureRecognizer === longPress { return gestureRecognizer.numberOfTouches == 1 }
        return true
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            let point = recognizer.location(in: scrollView)
            beginZoom(at: CGPoint(x: point.x, y: point.y - scrollView.contentOffset.y))
        case .changed:
            guard var zoom else { return }
            zoom.density = min(10, max(2, CGFloat(zoom.initialColumns) / max(0.01, recognizer.scale)))
            self.zoom = zoom
            renderZoom(density: zoom.density)
        case .ended: endZoom(cancelled: false)
        case .cancelled, .failed: endZoom(cancelled: true)
        default: break
        }
    }

    func beginZoom(at screenPoint: CGPoint) {
        guard !isLocked, let geometry, layouts.count == 9 else { return }
        let point = CGPoint(x: screenPoint.x, y: screenPoint.y + scrollView.contentOffset.y)
        guard let index = geometry.index(at: point, nearest: true), let frame = geometry.frame(at: index) else { return }
        stopScrollingToBeginning()
        preparation?.cancel(); preparation = nil
        if appliedSnapshot.revision != catalog.snapshot.revision { pendingSnapshot = catalog.snapshot }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        zoom = Zoom(initialColumns: columns, anchorIndex: index,
            unitY: min(1, max(0, (point.y - frame.minY) / frame.height)),
            screenY: screenPoint.y,
            horizontalEdge: screenPoint.x < geometry.width / 2 ? 0 : geometry.width,
            density: CGFloat(columns))
        lock(true)
        if isActive { fpsBooster.start() }
        zoomLabel.isHidden = false
        monthNodes.values.forEach { $0.isHidden = true }
        footerNode.isHidden = true
        renderZoom(density: CGFloat(columns))
        updateNearEnd()
    }

    func updateZoom(to density: CGFloat) {
        guard var zoom else { return }
        zoom.density = min(10, max(2, density)); self.zoom = zoom
        renderZoom(density: zoom.density)
    }

    private func renderZoom(density: CGFloat, refreshSources: Bool = false) {
        guard let zoom, let from = layouts[Int(floor(density))], let to = layouts[Int(ceil(density))],
              let a = from.frame(at: zoom.anchorIndex), let b = to.frame(at: zoom.anchorIndex) else { return }
        let fraction = density - floor(density)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fraction }
        let anchorY = mix(a.minY, b.minY)
        let side = mix(a.width, b.width)
        let desiredY = anchorY + side * zoom.unitY - zoom.screenY
        let contentHeight = mix(from.height, to.height) + 104
        let maxY = max(collapse - inset, contentHeight + bottomInset - view.bounds.height)
        let y = min(maxY, max(collapse - inset, desiredY))
        isAdjusting = true
        scrollView.contentSize.height = contentHeight
        scrollView.contentOffset.y = y
        isAdjusting = false
        let viewport = CGRect(x: 0, y: y, width: view.bounds.width, height: view.bounds.height)
        func transform(for frame: CGRect) -> CGAffineTransform {
            let scale = side / frame.width
            // The starting half chooses a fixed grid edge. The selected
            // photo anchors only vertical position: changing its column
            // must never drag the entire grid sideways under the fingers.
            return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: zoom.horizontalEdge * (1 - scale), ty: anchorY - frame.minY * scale)
        }
        let fromTransform = transform(for: a), toTransform = transform(for: b)
        let presentations: [(RoomMediaGeometry, CGAffineTransform, CGFloat)]
        if from.columns == to.columns {
            presentations = [(from, fromTransform, 1)]
        } else {
            // Bring in the destination before fading the source away. This
            // avoids a dark pulse between two transparent grid surfaces.
            let fromOpacity = 1 - max(0, (fraction - 0.7) / 0.3)
            presentations = [(from, fromTransform, fromOpacity), (to, toTransform, fraction)]
        }
        let ranges = presentations.map { layout, transform, _ in
            layout.range(in: viewport.applying(transform.inverted()).insetBy(dx: 0, dy: -40 / transform.d))
        }.filter { !$0.isEmpty }
        let range = (ranges.map(\.lowerBound).min() ?? 0)..<(ranges.map(\.upperBound).max() ?? 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let requiredColumns = Set(presentations.map { $0.0.columns })
        var surfacesChanged = false
        for columns in Array(zoomSurfaces.keys) where !requiredColumns.contains(columns) {
            zoomSurfaces.removeValue(forKey: columns)?.node.removeFromSupernode()
            surfacesChanged = true
        }
        if zoomSourceRange != range || refreshSources {
            zoomSourceRange = range
            // One pool owns image requests; both display surfaces share its
            // CGImages. Source frames stay fixed and hidden during the zoom.
            updateTiles(indices: range, visible: range, frame: { self.geometry?.frame(at: $0) },
                load: false, rebind: refreshSources,
                pixels: Self.pixelSize(for: max(from.side, to.side) * UIScreen.main.scale))
        }
        for (layout, transform, opacity) in presentations {
            let surface: RoomMediaZoomSurface
            if let existing = zoomSurfaces[layout.columns] { surface = existing }
            else {
                surface = RoomMediaZoomSurface(geometry: layout, footerText: footerNode.attributedText)
                zoomSurfaces[layout.columns] = surface
                node.addSubnode(surface.node)
                surfacesChanged = true
            }
            surface.update(transform: transform, viewport: viewport, opacity: opacity, source: { self.tiles[$0] })
        }
        if surfacesChanged, let top = zoomSurfaces[to.columns]?.node.view {
            // Reversing across an integer can create the lower-column
            // surface last; keep the compositing order independent of that.
            scrollView.bringSubviewToFront(top)
            scrollView.bringSubviewToFront(zoomLabel)
        }
        zoomLabel.text = "\(Int(density.rounded()))"
        zoomLabel.frame = CGRect(x: view.bounds.width - 56, y: y + inset - collapse + 12, width: 40, height: 28)
        CATransaction.commit()
        if appliedSnapshot.revision == catalog.snapshot.revision { catalog.ensure(range) }
    }

    func endZoom(cancelled: Bool, animated: Bool = true) {
        guard let zoom else { return }
        let destination = cancelled ? zoom.initialColumns : min(10, max(2, Int(zoom.density.rounded())))
        settleZoom(to: destination, animated: animated)
    }

    private func settleZoom(to destination: Int, animated: Bool) {
        guard let zoom else { return }
        if !animated || UIAccessibility.isReduceMotionEnabled { commitZoom(destination); return }
        animation = ZoomAnimation(start: CACurrentMediaTime(), density: zoom.density, destination: destination)
        linkTarget.tick = { [weak self] link in self?.animateZoom(link) }
        let link = CADisplayLink(target: linkTarget, selector: #selector(RoomMediaDisplayLinkTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink?.invalidate(); displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func animateZoom(_ link: CADisplayLink) {
        guard let animation else { return }
        let time = min(1, max(0, (link.timestamp - animation.start) / 0.22))
        let progress = CGFloat(1 - pow(1 - time, 3))
        let density = animation.density + (CGFloat(animation.destination) - animation.density) * progress
        zoom?.density = density
        renderZoom(density: density)
        if time >= 1 { commitZoom(animation.destination) }
    }

    private func commitZoom(_ destination: Int) {
        guard zoom != nil else { return }
        displayLink?.invalidate(); displayLink = nil; animation = nil
        fpsBooster.stop()
        renderZoom(density: CGFloat(destination))
        columns = destination; geometry = layouts[destination]; zoom = nil
        zoomSurfaces.values.forEach { $0.node.removeFromSupernode() }; zoomSurfaces.removeAll()
        zoomSourceRange = nil
        monthNodes.values.forEach { $0.isHidden = false }
        footerNode.isHidden = false
        zoomLabel.isHidden = true
        isAdjusting = true; padContent(); isAdjusting = false
        onAnchorRestored?(max(0, normalizedOffset - collapse))
        onColumnsChanged?(columns)
        lock(false)
        render(force: true); updateNearEnd()
    }

    func finishZoomImmediately() {
        if let zoom { commitZoom(min(10, max(2, Int(zoom.density.rounded())))) }
    }

    func setColumns(_ columns: Int, animated: Bool) {
        guard !isLocked, columns != self.columns else { return }
        beginZoom(at: CGPoint(x: view.bounds.midX, y: max(inset - collapse + 40, view.bounds.midY)))
        settleZoom(to: min(10, max(2, columns)), animated: animated)
    }

    private func updateAccessibility() {
        guard UIAccessibility.isVoiceOverRunning else { scrollView.accessibilityElements = nil; return }
        var elements: [(CGFloat, Any)] = []
        for (_, text) in monthNodes { elements.append((text.frame.minY, text.view)) }
        for index in visibleRange {
            guard let tile = tiles[index], let item = tile.item else { continue }
            let element = RoomMediaAccessibilityElement(accessibilityContainer: scrollView)
            element.accessibilityLabel = [item.kind == .video ? String(localized: "Video", table: "RoomProfile") : String(localized: "Photo"),
                                          item.date.formatted(date: .abbreviated, time: .omitted), item.caption ?? ""].joined(separator: ", ")
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = tile.frame
            element.activate = { [weak self] in self?.activate(index); return true }
            element.accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Show in Chat", table: "RoomProfile")) { [weak self] _ in
                self?.onShowInChat?(item); return true
            }] + zoomAccessibilityActions()
            elements.append((tile.frame.minY + CGFloat(index % columns) * 0.001, element))
        }
        if let label = renderedFooter, !label.isEmpty {
            let footer = RoomMediaAccessibilityElement(accessibilityContainer: scrollView)
            footer.accessibilityLabel = label
            footer.accessibilityFrameInContainerSpace = footerNode.frame
            footer.accessibilityTraits = self.footer.isAction || catalog.error != nil || preparationError != nil ? .button : .staticText
            footer.activate = { [weak self] in self?.activateFooter(); return true }
            elements.append((footerNode.frame.minY, footer))
        }
        scrollView.accessibilityElements = elements.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
