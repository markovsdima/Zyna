//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import AsyncDisplayKit
import Testing
import UIKit
@testable import Zyna

@Suite("Chat list playground", .serialized)
@MainActor
struct ChatListPlaygroundTests {
    private let insets = UIEdgeInsets(top: 60, left: 0, bottom: 80, right: 0)

    @Test("Replacing an anchor node retains its ID and includes motion during preparation")
    func anchorSurvivesReload() {
        let old = ChatListGeometry(ids: (0..<100).map(String.init), heights: Array(repeating: 40, count: 100))
        let next = ChatListGeometry(
            ids: ["earlier"] + old.ids, heights: [250] + old.heights
        )
        let target = next.offset(
            replacing: old, current: 437, viewport: 600, insets: insets, destination: .preserve
        )
        #expect(target == 687)
        #expect(next.origins[next.indices["12"]!] - target == old.origins[12] - 437)
    }

    @Test("Deleting every visible item falls back to a surviving neighbour")
    func deletedAnchor() {
        let old = ChatListGeometry(ids: (0..<100).map(String.init), heights: Array(repeating: 40, count: 100))
        let ids = old.ids.filter { !(10..<25).contains(Int($0)!) }
        let next = ChatListGeometry(ids: ids, heights: Array(repeating: 40, count: ids.count))
        let target = next.offset(
            replacing: old, current: 400, viewport: 600, insets: .zero, destination: .preserve
        )
        #expect(target.isFinite)
        #expect(next.origins[next.indices["9"]!] - target == old.origins[9] - 400)
    }

    @Test("Geometry finds only intersecting rows and supports an empty chat")
    func visibleRange() {
        let geometry = ChatListGeometry(ids: ["a", "b", "c"], heights: [10, 20, 30])
        #expect(geometry.range(in: CGRect(x: 0, y: 10, width: 1, height: 20)) == 1..<2)
        #expect(geometry.range(in: CGRect(x: 0, y: 60, width: 1, height: 20)).isEmpty)
        #expect(ChatListGeometry().limits(viewport: 800, insets: insets) == -60 ... -60)
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let root = ASDKViewController(node: ASDisplayNode())
        let preparation = ChatPlaygroundPreparation()
        let list: ChatPlaygroundCustomList

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            list = ChatPlaygroundCustomList(preparation: preparation)
            window.rootViewController = root
            window.isHidden = false
            root.loadViewIfNeeded()
            root.node.addSubnode(list.node)
            list.updateViewport(
                size: CGSize(width: 390, height: 700),
                insets: UIEdgeInsets(top: 60, left: 0, bottom: 80, right: 0)
            )
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func item(_ id: Int, height: CGFloat = 60, version: Int = 0) -> ChatPlaygroundItem {
            let row = ChatTimelineRow.message(ChatListPlaygroundController.localMessage(
                text: "\(id):\(version)", outgoing: false
            ))
            return ChatPlaygroundItem(id: String(id), row: row) {
                let content = ASCellNode()
                content.style.preferredSize = CGSize(width: 390, height: height)
                content.backgroundColor = .red
                return ChatPlaygroundRowNode(id: String(id), content: content)
            }
        }

        func snapshot(_ items: [ChatPlaygroundItem], width: CGFloat = 390) async -> ChatPlaygroundSnapshot {
            await withCheckedContinuation { continuation in
                preparation.prepare(items, width: width) { continuation.resume(returning: $0) }
            }
        }

        func apply(_ snapshot: ChatPlaygroundSnapshot, destination: ChatListDestination) async throws {
            let channel = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                channel.continuation.finish()
            }
            defer { timeout.cancel(); channel.continuation.finish() }
            list.apply(snapshot, destination: destination) {
                channel.continuation.yield(true)
                channel.continuation.finish()
            }
            var iterator = channel.stream.makeAsyncIterator()
            #expect(await iterator.next() == true, "List failed to finish its transaction")
            list.captureView.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("Custom preserves visible coordinates across leading insertion and reload")
    func leadingInsertion() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        var items = (0..<100).map { fixture.item($0) }
        try await fixture.apply(await fixture.snapshot(items), destination: .item("45"))
        let before = fixture.list.offset
        let anchorY = fixture.list.geometry.origins[45] - before
        items[45] = fixture.item(45, version: 1)
        let added = (-20..<0).map { fixture.item($0) }
        let prepared = await fixture.snapshot(added + items)
        // Motion after the snapshot was prepared must not be undone by commit.
        fixture.list.scrollView.contentOffset.y += 37
        try await fixture.apply(prepared, destination: .preserve)
        #expect(abs(fixture.list.offset - before - 1_200 - 37) < 1)
        let index = try #require(fixture.list.geometry.indices["45"])
        #expect(abs(fixture.list.geometry.origins[index] - fixture.list.offset - anchorY + 37) < 1)
        #expect(fixture.list.rowNode(id: "45") != nil)
    }

    @Test("Custom preserves the viewport when a preceding row grows")
    func precedingHeightChange() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        var items = (0..<100).map { fixture.item($0) }
        try await fixture.apply(await fixture.snapshot(items), destination: .item("45"))
        let before = fixture.list.offset
        items[4] = fixture.item(4, height: 320, version: 1)
        try await fixture.apply(await fixture.snapshot(items), destination: .preserve)
        #expect(abs(fixture.list.offset - before - 260) < 1)
    }

    @Test("An attached node can change height without a new datasource snapshot")
    func lateHeight() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let items = (0..<100).map { fixture.item($0) }
        try await fixture.apply(await fixture.snapshot(items), destination: .item("45"))
        let row = try #require(fixture.list.rowNode(id: "45"))
        row.content.style.preferredSize.height = 220
        row.content.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.list.geometry.heights[45] == 220)
        try await fixture.apply(await fixture.snapshot(items + [fixture.item(100)]), destination: .preserve)
        #expect(fixture.list.geometry.heights[45] == 220)
    }

    @Test("Custom list recenters its native scroller without moving visible content")
    func customRecentering() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let items = (0..<800).map { fixture.item($0) }
        try await fixture.apply(await fixture.snapshot(items), destination: .item("400"))
        let before = fixture.list.offset
        fixture.list.scrollView.contentOffset.y += 6_000
        #expect(abs(fixture.list.offset - before - 6_000) < 1)
        #expect(abs(fixture.list.scrollView.contentOffset.y - 10_000) < 1)
    }

    @Test("Custom installs asynchronously, moves one container, and retains nodes for reverse scrolling")
    func customInstallationAndRetention() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let snapshot = await fixture.snapshot((0..<200).map { fixture.item($0) })
        fixture.list.apply(snapshot, destination: .item("45")) {}
        // Applying a page must not synchronously load the whole preload band.
        #expect(snapshot.preparedNodes.values.allSatisfy { !$0.isNodeLoaded })
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.list.rowNode(id: "45") == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let row = try #require(fixture.list.rowNode(id: "45"))
        let frame = row.frame
        let before = row.view.convert(row.bounds, to: fixture.root.view)
        let boundsOrigin = fixture.list.captureView.bounds.origin.y
        fixture.list.scrollView.contentOffset.y += 12
        #expect(row.frame == frame)
        #expect(abs(fixture.list.captureView.bounds.origin.y - boundsOrigin - 12) < 0.5)
        #expect(abs(row.view.convert(row.bounds, to: fixture.root.view).minY - before.minY + 12) < 0.5)
        #expect(row.layer.superlayer === fixture.list.captureView.layer)

        fixture.list.scrollView.contentOffset.y += 2_800
        #expect(fixture.list.rowNode(id: "45") === row)
        #expect(row.supernode == nil)
        fixture.list.scroll(to: .item("45"))
        #expect(fixture.list.rowNode(id: "45") === row)
        #expect(row.layer.superlayer === fixture.list.captureView.layer)
        fixture.list.scroll(to: .item("140"))
        #expect(fixture.list.rowNode(id: "45") == nil)
    }

    @Test("An unchanged Custom snapshot preserves a native edge overscroll")
    func customRubberBand() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let snapshot = await fixture.snapshot((0..<100).map { fixture.item($0) })
        try await fixture.apply(snapshot, destination: .start)
        fixture.list.scrollView.contentOffset.y -= 40
        let logical = fixture.list.offset
        let native = fixture.list.scrollView.contentOffset
        fixture.list.apply(snapshot, destination: .preserve) {}
        #expect(fixture.list.offset == logical)
        #expect(fixture.list.scrollView.contentOffset == native)
    }

    @Test("Real portal bubbles return from the menu into the Custom capture hierarchy")
    func realBubbleMenu() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let source = BubbleGradientSource(colorProvider: { _ in [.green, .green] })
        source.frame = fixture.root.view.bounds
        fixture.root.view.insertSubview(source, at: 0)
        source.layoutIfNeeded()
        let items = (0..<30).map { index -> ChatPlaygroundItem in
            let message = ChatListPlaygroundController.localMessage(
                text: String(repeating: "A real portal bubble for the glass. ", count: 4),
                outgoing: true
            )
            return ChatPlaygroundItem(id: String(index), row: .message(message)) {
                let cell = TextMessageCellNode(message: message, isGroupChat: false)
                cell.bubbleGradientSource = source
                return ChatPlaygroundRowNode(id: String(index), content: cell)
            }
        }
        try await fixture.apply(await fixture.snapshot(items), destination: .item("15"))
        let row = try #require(fixture.list.rowNode(id: "15"))
        let cell = try #require(row.content as? MessageCellNode)
        cell.recursivelyEnsureDisplaySynchronously(true)
        let extracted = try #require(cell.extractBubbleForMenu(in: fixture.window.coordinateSpace))
        let originalParent = extracted.node.supernode
        let menu = ContextMenuController(
            contentNode: extracted.node, sourceFrame: extracted.frame,
            contentPath: { cell.contextMenuContentPath() },
            captureView: fixture.list.captureView, actions: []
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
        #expect(extracted.node.view.isDescendant(of: fixture.list.captureView))
        var iterator = completion.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(extracted.node.supernode === originalParent)
        #expect(extracted.node.view.window === fixture.window)
        func portal(in layer: CALayer) -> CALayer? {
            if layer.name == BubblePortalBackgroundNode.captureLayerName { return layer }
            return layer.sublayers?.compactMap { portal(in: $0) }.first
        }
        let layer = try #require(portal(in: cell.layer))
        let point = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            context.cgContext.translateBy(x: -point.x, y: -point.y)
            BubblePortalCaptureRenderer.renderLayerForCapture(
                layer, in: context.cgContext, clipRectInLayer: layer.bounds
            )
        }
        let pixel = try #require(image.cgImage?.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(pixel))
        // Green remains in the CPU fallback after both reparentings.
        #expect(bytes[1] > 200)

        // Exercise the actual capture root as well as the portal itself.
        // Custom scrolls via a nonzero bounds origin on that root.
        let capture = fixture.list.captureView.layer
        let backgroundPoint = CGPoint(x: layer.bounds.midX, y: layer.bounds.minY + 3)
        let capturePoint = layer.convert(backgroundPoint, to: capture)
        let captureImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            context.cgContext.translateBy(x: -capturePoint.x, y: -capturePoint.y)
            BubblePortalCaptureRenderer.renderLayerForCapture(
                capture, in: context.cgContext,
                clipRectInLayer: CGRect(origin: capturePoint, size: CGSize(width: 1, height: 1))
            )
        }
        let capturePixel = try #require(captureImage.cgImage?.dataProvider?.data)
        let captureBytes = try #require(CFDataGetBytePtr(capturePixel))
        #expect(captureBytes[1] > 200)
    }
}
#endif
