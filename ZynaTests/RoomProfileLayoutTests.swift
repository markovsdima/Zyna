// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private final class ProfileFixtureSource: AttachmentSource, @unchecked Sendable {
    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)?
    var onPaginationStatus: ((PaginationStatus) -> Void)?
    var onAttachmentsDiscovered: (([StoredRoomAttachment]) -> Void)?
    var onAttachmentsInvalidated: (([String]) -> Void)?
    var media = (0..<120).map { item($0) }
    var files = [item(500, kind: .file)]
    private var generation = 0

    static func item(_ index: Int, kind: RoomAttachmentKind = .image) -> AttachmentItem {
        let mxc = "mxc://profile.invalid/\(index)"
        return AttachmentItem(id: "$photo\(index)", uniqueId: "sdk\(index)", kind: kind,
            timestampMs: 1_790_784_000_000, sender: "@alice:example.org", senderName: "Alice", isOwn: false,
            filename: kind == .file ? "Design notes.pdf" : "Photo \(index)", caption: nil,
            mimetype: kind == .file ? "application/pdf" : "image/jpeg", sizeBytes: nil,
            pixelWidth: 300, pixelHeight: 300, durationSeconds: nil,
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj", isAnimated: false,
            source: try! MediaSource.fromUrl(url: mxc), sourceMxc: mxc, isSourceEncrypted: true, thumbnail: nil)
    }

    @MainActor func publish() {
        generation += 1
        func groups(_ items: [AttachmentItem]) -> [AttachmentMonthGroup] {
            items.isEmpty ? [] : [.init(id: "2026-09", title: "September 2026", items: items)]
        }
        onSnapshot?(.init(generation: generation, rowCount: media.count + files.count,
            media: groups(media), voice: [], files: groups(files), mediaCount: media.count,
            voiceCount: 0, fileCount: files.count, pendingCount: 0, pendingSessionIds: []), .init())
    }

    func start() async throws { await publish() }
    func stop() {}
    func loadMore(numEvents: UInt16) async throws -> Bool { true }
    func retryDecryption(sessionIds: [String]) {}
    func describeTimelineItem(eventId: String) async -> String? { nil }
    func storeRowDescription(uniqueId: String) -> String? { nil }
}

@Suite("Texture profile layout", .serialized)
@MainActor
struct RoomProfileLayoutTests {
    private func find<T: UIView>(_ type: T.Type, in root: UIView, id: String) -> T? {
        if root.accessibilityIdentifier == id { return root as? T }
        return root.subviews.lazy.compactMap { find(type, in: $0, id: id) }.first
    }

    private func itemCount(_ view: UICollectionView) -> Int {
        view.numberOfSections > 0 ? view.numberOfItems(inSection: 0) : 0
    }

    private func wait(sourceLocation: SourceLocation = #_sourceLocation,
                      diagnostics: () -> String = { "Condition did not become true" },
                      _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "\(diagnostics())", sourceLocation: sourceLocation)
    }

    @Test("Video opens with the displayed grid image even when the legacy cache has no matching size")
    func videoPreview() async throws {
        let source = ProfileFixtureSource()
        source.media = [ProfileFixtureSource.item(1, kind: .video)]
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 416)
        var preview: UIImage?
        var opened = false
        var actions = RoomAttachmentsActions.none
        actions.openVideo = { _, image, _, _ in preview = image; opened = true }
        let controller = RoomProfileViewController(room: nil, title: "Video", subtitle: "", model: model, actions: actions)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let grid = try #require(controller.mediaGrid)
        try await wait { grid.geometry?.count == 1 }
        let tile = try #require(grid.scrollView.layer.sublayers?.compactMap { $0 as? RoomMediaTileLayer }.first)
        try await wait { tile.image != nil }
        let displayed = try #require(tile.image)
        #expect(model.previewImage(for: source.media[0]) == nil)
        grid.activate(0)
        #expect(opened)
        #expect(preview === displayed)
    }

    @Test("Back owns right swipes across the first page, and only the leading edge elsewhere")
    func backSwipePriority() {
        let pager = RoomProfilePagerScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        pager.contentSize = CGSize(width: 1206, height: 874)
        var firstPageSettled = true
        pager.canStartBackFromAnywhere = { firstPageSettled }
        for x: CGFloat in [12, 180, 390] {
            let point = CGPoint(x: x, y: 500)
            #expect(pager.allowsInteractiveBack(at: point))
            #expect(pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: 200, y: 30)))
            #expect(!pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: -200, y: 30)))
            #expect(!pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: 30, y: 200)))
            #expect(!pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: 30, y: -200)))
        }

        firstPageSettled = false
        for offset: CGFloat in [0, 201, 402, 804] {
            pager.contentOffset.x = offset
            let edge = CGPoint(x: offset + 12, y: 500)
            let center = CGPoint(x: offset + 180, y: 500)
            #expect(pager.allowsInteractiveBack(at: edge))
            #expect(!pager.allowsInteractiveBack(at: center))
            #expect(pager.yieldsPanToInteractiveBack(from: edge, velocity: CGPoint(x: 200, y: 0)))
            #expect(!pager.yieldsPanToInteractiveBack(from: center, velocity: CGPoint(x: 200, y: 0)))
            #expect(!pager.yieldsPanToInteractiveBack(from: edge, velocity: CGPoint(x: -200, y: 0)))
        }

        // A zoom/menu interaction locks both competing horizontal gestures.
        firstPageSettled = true
        pager.isScrollEnabled = false
        #expect(!pager.allowsInteractiveBack(at: CGPoint(x: pager.bounds.minX + 12, y: 500)))
        #expect(!pager.allowsInteractiveBack(at: CGPoint(x: pager.bounds.midX, y: 500)))
    }

    @Test("Short and empty sections preserve media depth through cancellation, eviction and returning")
    func session() async throws {
        let source = ProfileFixtureSource()
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Design team",
            subtitle: "12 members", model: model, actions: .none)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let media = try #require(find(UIScrollView.self, in: controller.view, id: "profile.media"))
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        let tabs = try #require(find(UISegmentedControl.self, in: controller.view, id: "profile.sections"))
        func backFromCenter() -> Bool {
            pager.allowsInteractiveBack(at: CGPoint(x: pager.bounds.midX, y: pager.bounds.midY))
        }
        try await wait { controller.mediaGrid?.geometry?.count == 120 && media.contentSize.height > 2000 }
        media.contentOffset.y = 1200 - 48
        let deepOffset = media.contentOffset.y
        let height = media.contentInset.top - 48
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY) < 1)
        #expect(backFromCenter())

        controller.scrollViewWillBeginDragging(pager)
        #expect(!backFromCenter())
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        #expect(!backFromCenter())
        let files = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.files"))
        try await wait { itemCount(files) == 3 }
        #expect(abs(files.contentOffset.y + 48) < 1)
        #expect(files.contentSize.height + files.contentInset.bottom >= files.bounds.height - 48)
        files.contentOffset.y = -files.contentInset.top
        #expect(abs(media.contentOffset.y - (deepOffset - height)) < 1)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 0.5
        #expect(!backFromCenter())
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY - height * 0.5) < 1)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        #expect(!backFromCenter())
        #expect(abs(files.contentOffset.y + files.contentInset.top) < 1)

        controller.didReceiveMemoryWarning()
        #expect(find(UIScrollView.self, in: controller.view, id: "profile.media") == nil)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = 0
        #expect(!backFromCenter())
        controller.scrollViewDidEndDecelerating(pager)
        #expect(backFromCenter())
        let restored = try #require(find(UIScrollView.self, in: controller.view, id: "profile.media"))
        let grid = try #require(controller.mediaGrid)
        try await wait { grid.geometry?.count == 120 && restored.contentSize.height > 2000 }
        #expect(abs(restored.contentOffset.y - deepOffset) < 1)
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY) < 1)

        // Inserts before the viewport retain the same visible event and gap.
        let oldPath = try #require(grid.geometry?.index(at: CGPoint(x: 20, y: restored.contentOffset.y + 60)))
        let oldFrame = try #require(grid.frameForItem(at: oldPath))
        let gap = restored.contentOffset.y - oldFrame.minY
        source.media.insert(contentsOf: (200..<203).map { ProfileFixtureSource.item($0) }, at: 0)
        source.publish()
        try await wait { grid.geometry?.count == 123 }
        let shifted = try #require(grid.frameForItem(at: oldPath + 3))
        #expect(abs(restored.contentOffset.y - shifted.minY - gap) < 1)

        let top = try #require(find(UIButton.self, in: controller.view, id: "profile.scrollToTop"))
        let beforeTop = restored.contentOffset.y
        top.sendActions(for: .touchUpInside)
        #expect(restored.contentOffset.y > 0)
        try await wait { restored.contentOffset.y < beforeTop - 1 && restored.contentOffset.y > 0 }
        let interrupted = restored.contentOffset.y
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        try await Task.sleep(for: .milliseconds(400))
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = 0
        controller.scrollViewDidEndDecelerating(pager)
        #expect(abs(restored.contentOffset.y - interrupted) < 1)
        top.sendActions(for: .touchUpInside)
        try await wait { !grid.isScrollingToBeginning && abs(restored.contentOffset.y + 48) < 1 }
        #expect(abs(restored.contentOffset.y + 48) < 1)
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY) < 1)
        source.files = []
        source.publish()
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        // Texture publishes the new item count before its batch completion
        // restores padding and offset. Wait for the completed presentation.
        try await wait(diagnostics: {
            "Empty files: count=\(itemCount(files)), offset=\(files.contentOffset), inset=\(files.contentInset), "
                + "size=\(files.contentSize), tabsY=\(tabs.superview!.frame.minY), pagerY=\(pager.frame.minY)"
        }) { itemCount(files) == 1 && abs(files.contentOffset.y + 48) < 1 }
        #expect(abs(files.contentOffset.y + 48) < 1)
        files.contentOffset.y = -files.contentInset.top
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY - height) < 1)
    }

    @Test("Parent layout and queued scroll corrections during file deletion cannot reopen the header", arguments: [false, true])
    func layoutDuringFileDeletion(queuedCorrection: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        let page = RoomProfileFilePage()
        defer { page.onScroll = nil; window.isHidden = true; window.rootViewController = nil }
        host.view.addSubview(page.view)
        page.install()
        page.isActive = true
        var state = RoomProfileScrollState()
        state.scroll(to: state.headerHeight)
        page.headerHeight = state.headerHeight
        page.collapse = state.collapse
        page.onScroll = {
            state.scroll(to: page.normalizedOffset)
            page.collapse = state.collapse
        }
        page.layout(frame: host.view.bounds, depth: 0, bottomInset: 0)
        let footer = RoomProfileRow(id: "footer", title: "No files", detail: nil,
                                    item: nil, isHeader: false, isAction: false)
        page.update(RoomProfileRow.rows(groups: [.init(id: "month", title: "September",
            items: [ProfileFixtureSource.item(1, kind: .file)])]) + [footer])
        try await wait { itemCount(page.node.view) == 3 && !page.isAdjusting }

        var nestedLayouts = 0
        let observation = page.scrollView.observe(\.contentSize, options: [.old, .new]) { _, change in
            MainActor.assumeIsolated {
                guard change.oldValue != change.newValue, page.isAdjusting else { return }
                nestedLayouts += 1
                page.layout(frame: host.view.bounds, depth: state.depth(for: state.selected), bottomInset: 0)
                #expect(page.isAdjusting)
                if queuedCorrection, let oldSize = change.oldValue, let newSize = change.newValue, oldSize.height > newSize.height {
                    // Reproduce UIKit's pending correction before its first
                    // frame, while the model offset is still at the anchor.
                    page.scrollView.setContentOffset(CGPoint(x: 0,
                        y: page.scrollView.contentOffset.y + newSize.height - oldSize.height), animated: true)
                }
            }
        }
        defer { observation.invalidate() }
        page.update([footer])
        try await wait { itemCount(page.node.view) == 1 && !page.isAdjusting }
        // Observe a full scroll animation interval: checking its first frame
        // alone would miss an uncancelled correction that has not moved yet.
        if queuedCorrection { try await Task.sleep(for: .milliseconds(400)) }
        #expect(nestedLayouts > 0)
        #expect(abs(page.scrollView.contentOffset.y + page.tabsHeight) < 1)
        #expect(state.collapse == state.headerHeight)
    }

    @Test("A file menu extracts only its attachment, restores it and keeps the stable event action")
    func itemContextMenu() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        let page = RoomProfileFilePage()
        defer { page.dismissContextMenu(); window.isHidden = true; window.rootViewController = nil }
        host.view.addSubview(page.node.view)
        page.install()
        page.isActive = true
        page.collapse = page.headerHeight
        page.layout(frame: host.view.bounds, depth: 0, bottomInset: 0)
        let items = (1...3).map { ProfileFixtureSource.item($0, kind: .file) }
        let rows = RoomProfileRow.rows(groups: [.init(id: "month", title: "September", items: items)])
        page.update(rows)
        try await wait { itemCount(page.node.view) == 4 && !page.isAdjusting }
        page.node.view.layoutIfNeeded()
        let cell = try #require(page.node.nodeForItem(at: IndexPath(item: 1, section: 0)) as? ListContextMenuCellNode)
        let other = try #require(page.node.nodeForItem(at: IndexPath(item: 2, section: 0)) as? ListContextMenuCellNode)
        let source = cell.extractContentForMenu(in: window.coordinateSpace)
        var selectedEvent: String?
        page.onShowInChat = { selectedEvent = $0.id }
        cell.onContextMenuActivated?(.init(x: 20, y: 20))
        let overlay = try #require(source.node.view.window)
        #expect(overlay !== window)
        #expect(page.node.view.window === window)
        #expect(other.view.window === window)
        #expect(source.node.bounds.size == cell.bounds.size)
        #expect(source.node.bounds.height < page.node.bounds.height)
        #expect(!page.scrollView.isScrollEnabled)
        #expect(page.node.view.interactions.allSatisfy { !($0 is UIContextMenuInteraction) })

        // An incoming edit waits for restoration instead of replacing the
        // cell underneath the raised preview or changing the action's ID.
        page.update(Array(rows.dropLast()))
        try await Task.sleep(for: .milliseconds(400))
        #expect(itemCount(page.node.view) == 4)
        func action(in view: UIView) -> UIControl? {
            if let control = view as? UIControl,
               control.accessibilityLabel == String(localized: "Show in Chat", table: "RoomProfile") { return control }
            return view.subviews.lazy.compactMap { action(in: $0) }.first
        }
        let button = try #require(action(in: overlay))
        button.sendActions(for: .touchUpInside)
        try await wait { selectedEvent != nil && itemCount(page.node.view) == 3 }
        #expect(selectedEvent == items[0].id)
        #expect(source.node.view.window === window)
        #expect(page.scrollView.isScrollEnabled)
    }
}
