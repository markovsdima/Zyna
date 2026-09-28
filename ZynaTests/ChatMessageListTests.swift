//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Testing
import UIKit
@testable import Zyna

@Suite("Full chat collection container", .serialized)
@MainActor
struct ChatMessageListTests {
    private struct Item {
        let id: Int
        var height: CGFloat = 60
    }

    private final class MeasuredCell: ASCellNode {
        var mainSizeReads = 0

        override var calculatedSize: CGSize {
            if Thread.isMainThread { mainSizeReads += 1 }
            return super.calculatedSize
        }
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let root = ASDKViewController(node: ASDisplayNode())
        let list: ChatMessageList
        var items = (0..<100).map { Item(id: $0) }

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            list = ChatMessageList()
            list.numberOfRows = { [weak self] in self?.items.count ?? 0 }
            list.itemIdentifier = { [weak self] path in String(self!.items[path.row].id) }
            list.nodeBlock = { [weak self] path in
                let item = self!.items[path.row]
                return {
                    let node = MeasuredCell()
                    node.style.preferredSize = CGSize(width: 390, height: item.height)
                    node.backgroundColor = .red
                    return node
                }
            }
            window.rootViewController = root
            window.isHidden = false
            root.loadViewIfNeeded()
            root.node.addSubnode(list.node)
            list.node.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            list.view.contentInsetAdjustmentBehavior = .never
            list.contentInset = UIEdgeInsets(top: 60, left: 0, bottom: 80, right: 0)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func ready() async throws {
            let channel = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                channel.continuation.finish()
            }
            defer { timeout.cancel(); channel.continuation.finish() }
            list.onDidFinishProcessingUpdates {
                channel.continuation.yield(true)
                channel.continuation.finish()
            }
            var iterator = channel.stream.makeAsyncIterator()
            try #require(await iterator.next() == true)
            list.view.layoutIfNeeded()
        }

        func load() async throws {
            list.reloadData()
            try await ready()
            #expect(list.view.contentSize.height == 6_000)
            list.contentOffset.y = 1_200
            list.view.layoutIfNeeded()
        }

        func screenY(id: Int) throws -> CGFloat {
            let index = try #require(items.firstIndex { $0.id == id })
            let rect = list.rectForItem(at: IndexPath(row: index, section: 0))
            try #require(rect.height > 0)
            return list.view.convert(rect, to: root.view).minY
        }

        func insert(_ ids: Range<Int>) {
            items.insert(contentsOf: ids.map { Item(id: $0) }, at: 0)
            list.performBatch(
                animated: false, preservingViewport: true,
                insertions: (0..<ids.count).map { IndexPath(row: $0, section: 0) }
            )
        }
    }

    @Test("The real container keeps inversion and measured message geometry")
    func measuredCells() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        #expect(fixture.list.view.transform.d == -1)
        #expect(fixture.list.view.alwaysBounceVertical)
        #expect(fixture.list.layout.geometry.ids[20] == "20")
        #expect(fixture.list.rectForItem(at: IndexPath(row: 20, section: 0)).height == 60)
        #expect(!fixture.list.indexPathsForVisibleItems().isEmpty)
    }

    @Test("A leading page preserves the bubble and motion during Texture preparation")
    func leadingPage() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        let y = try fixture.screenY(id: 23)
        fixture.insert(-20..<0)
        // Texture measures the page asynchronously; this motion must survive.
        fixture.list.contentOffset.y += 37
        try await fixture.ready()
        #expect(abs(fixture.list.contentOffset.y - 2_437) < 1)
        // The view is inverted, so increasing its offset moves content down.
        #expect(abs(try fixture.screenY(id: 23) - y - 37) < 1)
        let proposed = CGPoint(x: 0, y: 2_600)
        #expect(fixture.list.layout.targetContentOffset(forProposedContentOffset: proposed) == proposed)
    }

    @Test("Queued pages use their committed map rather than the latest datasource")
    func queuedPages() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        let y = try fixture.screenY(id: 23)
        fixture.insert(-10..<0)
        fixture.insert(-20 ..< -10)
        try await fixture.ready()
        #expect(abs(fixture.list.contentOffset.y - 2_400) < 1)
        #expect(abs(try fixture.screenY(id: 23) - y) < 1)
        #expect(fixture.list.layout.geometry.ids == fixture.items.map { String($0.id) })
    }

    @Test("A queued appearance reload cannot consume the next page's policy", arguments: [false, true])
    func reloadBeforePage(preservePage: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        if preservePage { fixture.list.contentOffset.y = -60 }
        fixture.items[3].height = 220
        fixture.list.performBatch(
            animated: false, preservingViewport: true,
            reloads: [IndexPath(row: 3, section: 0)]
        )
        // Submit before the reload commits. At the live edge the page's true
        // policy differs from the fallback; away from it, false differs.
        fixture.items.insert(contentsOf: (-10..<0).map { Item(id: $0) }, at: 0)
        fixture.list.performBatch(
            animated: false, preservingViewport: preservePage,
            insertions: (0..<10).map { IndexPath(row: $0, section: 0) }
        )
        try await fixture.ready()
        #expect(abs(fixture.list.contentOffset.y - (preservePage ? 540 : 1_360)) < 1)
        #expect(fixture.list.layout.geometry.heights[13] == 220)
    }

    @Test("Empty and reload-skipped batches leave no policy for a later update")
    func skippedPolicies() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        fixture.list.reloadData()
        fixture.insert(-10..<0)
        fixture.list.performBatch(animated: false, preservingViewport: true)
        try await fixture.ready()
        let offset = fixture.list.contentOffset.y
        fixture.items.insert(Item(id: -11), at: 0)
        fixture.list.performBatch(
            animated: false, preservingViewport: false,
            insertions: [IndexPath(row: 0, section: 0)]
        )
        try await fixture.ready()
        #expect(abs(fixture.list.contentOffset.y - offset) < 1)
        #expect(fixture.list.layout.geometry.ids == fixture.items.map { String($0.id) })
    }

    @Test("Repeated layout passes reuse measured geometry until the width changes")
    func geometryReuse() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        let cells = try (0..<fixture.items.count).map {
            try #require(fixture.list.nodeForItem(at: IndexPath(row: $0, section: 0)) as? MeasuredCell)
        }
        let reads = cells.reduce(0) { $0 + $1.mainSizeReads }
        let layout = fixture.list.layout
        layout.invalidateLayout()
        layout.prepare()
        layout.prepare(forCollectionViewUpdates: [])
        #expect(cells.reduce(0) { $0 + $1.mainSizeReads } == reads)
        fixture.list.node.frame.size.width = 350
        layout.invalidateLayout()
        layout.prepare()
        #expect(cells.reduce(0) { $0 + $1.mainSizeReads } > reads)
        #expect(layout.collectionViewContentSize.width == 350)
        #expect(layout.layoutAttributesForItem(at: IndexPath(row: 23, section: 0))?.frame.width == 350)
    }

    @Test("Duplicate identities retain rows and anchor only to an unambiguous neighbour", arguments: [0, 1, 2])
    func duplicateIdentities(transition: Int) {
        let unique = ["a", "b", "c", "d", "e", "f"]
        let duplicated = ["a", "b", "c", "c", "d", "e", "f"]
        let movedDuplicate = ["c", "a", "b", "c", "d", "e", "f"]
        let oldIDs = transition == 0 ? unique : duplicated
        let newIDs = transition == 1 ? unique : movedDuplicate
        let old = ChatListGeometry(ids: oldIDs, heights: Array(repeating: 100, count: oldIDs.count))
        let next = ChatListGeometry(ids: newIDs, heights: Array(repeating: 100, count: newIDs.count))
        let target = next.offset(
            replacing: old, current: 210, viewport: 200, insets: .zero, destination: .preserve
        )
        #expect(next.ids == newIDs)
        #expect(next.height == CGFloat(newIDs.count) * 100)
        #expect(target == [310, 110, 210][transition])
    }

    @Test("Entirely ambiguous identities fall back without dropping rows")
    func allDuplicateIdentities() {
        let old = ChatListGeometry(ids: ["a", "a", "a"], heights: [100, 100, 100])
        let next = ChatListGeometry(ids: ["a", "a"], heights: [100, 100])
        #expect(next.height == 200)
        #expect(next.indices.isEmpty)
        #expect(next.offset(replacing: old, current: 200, viewport: 100, insets: .zero, destination: .preserve) == 100)
        #expect(next.offset(replacing: old, current: 50, viewport: 100, insets: .zero, destination: .item("a")) == 50)
    }

    @Test("A later deletion compensates once and retains intervening scroll motion")
    func consecutiveUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        let y = try fixture.screenY(id: 23)
        fixture.insert(-10..<0)
        try await fixture.ready()
        #expect(abs(fixture.list.contentOffset.y - 1_800) < 1)
        fixture.list.contentOffset.y += 23
        fixture.items.removeFirst(5)
        fixture.list.performBatch(
            animated: false, preservingViewport: true,
            deletions: (0..<5).map { IndexPath(item: $0, section: 0) }
        )
        try await fixture.ready()
        #expect(abs(fixture.list.contentOffset.y - 1_523) < 1)
        #expect(abs(try fixture.screenY(id: 23) - y - 23) < 1)
        let proposed = CGPoint(x: 0, y: 1_600)
        #expect(fixture.list.layout.targetContentOffset(forProposedContentOffset: proposed) == proposed)
    }

    @Test("Replacing the anchor node retains its stable message identity")
    func anchorReload() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        let y = try fixture.screenY(id: 23)
        let oldAnchor = fixture.list.nodeForItem(at: IndexPath(row: 23, section: 0))
        fixture.items[3].height = 220
        fixture.list.performBatch(
            animated: false, preservingViewport: true,
            reloads: [3, 21, 22, 23].map { IndexPath(row: $0, section: 0) }
        )
        try await fixture.ready()
        #expect(fixture.list.nodeForItem(at: IndexPath(row: 23, section: 0)) !== oldAnchor)
        #expect(fixture.list.layout.geometry.heights[3] == 220)
        #expect(abs(fixture.list.contentOffset.y - 1_360) < 1)
        #expect(abs(try fixture.screenY(id: 23) - y) < 1)
    }

    @Test("A late media height change preserves the viewport")
    func lateHeight() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        let y = try fixture.screenY(id: 23)
        let cell = try #require(fixture.list.nodeForItem(at: IndexPath(row: 3, section: 0)))
        let visibleCell = try #require(fixture.list.view.cellForItem(at: IndexPath(row: 23, section: 0)))
        let map = fixture.list.node.visibleElements
        #expect(!cell.shouldAnimateSizeChanges)
        cell.style.preferredSize.height = 220
        cell.setNeedsLayout()
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.list.layout.geometry.heights[3] != 220, ContinuousClock.now < deadline {
            fixture.list.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.list.layout.geometry.heights[3] == 220)
        #expect(fixture.list.node.visibleElements === map)
        #expect(abs(try fixture.screenY(id: 23) - y) < 1)
        let animatedGeometry = (visibleCell.layer.animationKeys() ?? []).compactMap {
            visibleCell.layer.animation(forKey: $0) as? CAPropertyAnimation
        }.contains { animation in
            animation.keyPath?.hasPrefix("position") == true || animation.keyPath?.hasPrefix("bounds") == true
        }
        #expect(!animatedGeometry)
    }

    @Test("An appearance-only reload keeps the history viewport")
    func appearanceReload() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        let y = try fixture.screenY(id: 23)
        fixture.items[3].height = 220
        fixture.list.performBatch(
            animated: false, preservingViewport: true,
            reloads: [IndexPath(row: 3, section: 0)]
        )
        try await fixture.ready()
        #expect(fixture.list.layout.geometry.heights[3] == 220)
        #expect(abs(try fixture.screenY(id: 23) - y) < 1)
    }

    @Test("A live insertion stays at the live edge without viewport preservation", arguments: [false, true])
    func liveInsertion(animated: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.load()
        fixture.list.contentOffset.y = -60
        fixture.items.insert(Item(id: -1), at: 0)
        fixture.list.performBatch(
            animated: animated, preservingViewport: false,
            insertions: [IndexPath(row: 0, section: 0)]
        )
        try await fixture.ready()
        #expect(abs(fixture.list.contentOffset.y + 60) < 1)
    }

    @Test("Real message nodes return under glass in the chat collection")
    func realBubbleMenu() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = BubbleGradientSource(colorProvider: { _ in [.green, .green] })
        source.frame = fixture.root.view.bounds
        fixture.root.view.insertSubview(source, at: 0)
        source.layoutIfNeeded()
        fixture.list.nodeBlock = { path in
            let message = ChatMessage(
                id: "capture:\(path.row)", eventId: nil, transactionId: nil, itemIdentifier: nil,
                senderId: "@capture:local", senderDisplayName: "Capture", senderAvatarUrl: nil,
                isOutgoing: true, timestamp: Date(),
                content: .text(body: String(repeating: "A real portal bubble. ", count: 5)),
                reactions: [], replyInfo: nil, isEditable: false, isEdited: false,
                isEditPending: false, isEditFailed: false, latestEditEventId: nil,
                zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced"
            )
            return {
                let cell = TextMessageCellNode(message: message, isGroupChat: false)
                cell.bubbleGradientSource = source
                return cell
            }
        }
        fixture.list.reloadData()
        try await fixture.ready()
        fixture.list.scrollToItem(at: IndexPath(row: 20, section: 0), at: .centeredVertically, animated: false)
        fixture.list.view.layoutIfNeeded()
        // The adapter exposes the real cell directly, with no playground wrapper.
        let cell = try #require(fixture.list.nodeForItem(at: IndexPath(row: 20, section: 0)) as? TextMessageCellNode)
        cell.recursivelyEnsureDisplaySynchronously(true)
        let extracted = try #require(cell.extractBubbleForMenu(in: fixture.window.coordinateSpace))
        let originalParent = extracted.node.supernode
        let menu = ContextMenuController(
            contentNode: extracted.node, sourceFrame: extracted.frame,
            contentPath: { cell.contextMenuContentPath() },
            captureView: fixture.list.view, actions: []
        )
        menu.onDismissComplete = { cell.restoreBubbleFromMenu() }
        menu.show(in: fixture.window)
        try await Task.sleep(for: .milliseconds(450))
        #expect(extracted.node.view.window !== fixture.window)
        let completion = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            completion.continuation.finish()
        }
        defer { timeout.cancel(); completion.continuation.finish() }
        menu.dismissMenu {
            completion.continuation.yield(true)
            completion.continuation.finish()
        }
        #expect(extracted.node.view.isDescendant(of: fixture.list.view))
        var iterator = completion.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(extracted.node.supernode === originalParent)
        #expect(extracted.node.view.window === fixture.window)

        func portal(in layer: CALayer) -> CALayer? {
            if layer.name == BubblePortalBackgroundNode.captureLayerName { return layer }
            return layer.sublayers?.compactMap { portal(in: $0) }.first
        }
        let layer = try #require(portal(in: cell.layer))
        let capture = fixture.list.view.layer
        let point = layer.convert(CGPoint(x: layer.bounds.midX, y: layer.bounds.minY + 3), to: capture)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            context.cgContext.translateBy(x: -point.x, y: -point.y)
            BubblePortalCaptureRenderer.renderLayerForCapture(
                capture, in: context.cgContext,
                clipRectInLayer: CGRect(origin: point, size: CGSize(width: 1, height: 1))
            )
        }
        let data = try #require(image.cgImage?.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        #expect(bytes[1] > 200)
    }
}
