//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Testing
import UIKit
@testable import Zyna

@Suite("Context menu dismissal", .serialized)
@MainActor
struct ContextMenuDismissalTests {
    /// A single callback wait. Buffer early completion; finishing the stream
    /// makes late/repeated callbacks harmless and cancellation ends next().
    @MainActor
    private struct CallbackCompletion {
        private let channel = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))

        func complete() {
            channel.continuation.yield(true)
            channel.continuation.finish()
        }

        func wait(timeout: Duration) async -> Bool {
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                channel.continuation.finish()
            }
            defer {
                timer.cancel()
                channel.continuation.finish()
            }
            var iterator = channel.stream.makeAsyncIterator()
            return await iterator.next() == true
        }
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let table = UIView()
        let cell = ASDisplayNode()
        let content = ASDisplayNode()
        let source: ContextSourceNode
        let gradient = PortalSourceView()
        let portal = BubblePortalBackgroundNode()
        var restorationCount = 0

        init(height: CGFloat = 150) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.rootViewController = UIViewController()
            window.isHidden = false
            let root = window.rootViewController!.view!
            root.frame = window.bounds
            gradient.frame = root.bounds
            gradient.alpha = 0
            let canvas = UIView(frame: gradient.bounds)
            canvas.backgroundColor = .green
            gradient.addSubview(canvas)
            root.addSubview(gradient)

            table.frame = root.bounds
            table.bounds.origin.y = 123
            table.transform = CGAffineTransform(scaleX: 1, y: -1)
            root.addSubview(table)
            cell.frame = table.bounds
            cell.transform = CATransform3DMakeScale(1, -1, 1)
            table.addSubview(cell.view)
            source = ContextSourceNode(contentNode: content)
            source.frame = CGRect(x: 30, y: root.bounds.height - 190, width: 240, height: height)
            cell.addSubnode(source)
            content.frame = source.bounds
            portal.frame = content.bounds
            portal.radius = 14
            portal.sourceView = gradient
            content.addSubnode(portal)
            portal.view.layoutIfNeeded()
        }

        func menu() -> ContextMenuController {
            let info = source.extractContentForMenu(in: window.coordinateSpace)
            let menu = ContextMenuController(
                contentNode: info.node, sourceFrame: info.frame,
                contentPath: { [content, portal] in
                    UIBezierPath(
                        roundedRect: portal.view.convert(portal.bounds, to: content.view),
                        byRoundingCorners: portal.roundedCorners,
                        cornerRadii: CGSize(width: portal.radius, height: portal.radius)
                    ).cgPath
                },
                captureView: table,
                actions: [ContextMenuAction(title: "Copy", image: nil, handler: {})]
            )
            menu.onDismissComplete = { [self] in
                restorationCount += 1
                source.restoreContentFromMenu()
            }
            menu.show(in: window)
            return menu
        }

        func settle(_ milliseconds: Int = 60) async throws {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(milliseconds))
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @Test("The live portal enters capture before returning, then restores its Texture parent once")
    func returnsUnderGlass() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.settle()
        let menu = fixture.menu()
        try await fixture.settle(450)
        let menuWindow = try #require(fixture.content.view.window)
        #expect(menuWindow !== fixture.window)
        let host = fixture.content.supernode
        let scroll = try #require(host?.view.superview as? UIScrollView)
        let before = scroll.convert(scroll.bounds, to: fixture.window)
        let dismissed = CallbackCompletion()
        menu.dismissMenu { dismissed.complete() }
        menu.dismissMenu { Issue.record("A duplicate dismissal must not run another action") }
        #expect(fixture.content.view.isDescendant(of: fixture.table))
        #expect(fixture.content.supernode === host)
        #expect(fixture.restorationCount == 0)
        CATransaction.flush()
        let presented = try #require(scroll.layer.presentation())
        let windowLayer = fixture.window.layer.presentation() ?? fixture.window.layer
        let after = presented.convert(presented.bounds, to: windowLayer)
        #expect(abs(after.minY - before.minY) < 2)
        #expect(abs(after.minX - before.minX) < 1)
        let mask = try #require(menuWindow.rootViewController?.view.subviews.first?.layer.mask?.presentation())
        #expect(alpha(of: mask, at: CGPoint(x: before.midX, y: before.midY)) < 0.02)
        #expect(alpha(of: mask, at: CGPoint(x: before.minX + 1, y: before.minY + 1)) > 0.98)

        try await fixture.settle(80)
        let captureLayer = try #require(fixture.table.layer.presentation())
        let portalLayer = try #require(fixture.portal.layer.presentation())
        let point = captureLayer.convert(
            CGPoint(x: portalLayer.bounds.midX, y: portalLayer.bounds.midY), from: portalLayer
        )
        #expect(alpha(of: captureLayer, at: point, portalFallback: true) > 0.95)
        // The dismissal completion runs after restoration and transition
        // cleanup. Wait for that event rather than assuming a frame budget.
        try #require(await dismissed.wait(timeout: .seconds(2)), "Menu dismissal timed out or was cancelled")
        #expect(fixture.restorationCount == 1)
        #expect(fixture.content.supernode === fixture.source)
        #expect(fixture.content.frame == fixture.source.bounds)
        #expect(fixture.content.view.transform.isIdentity)
        #expect(fixture.table.subviews.count == 1)
        #expect(menuWindow.isHidden)
    }

    @Test("Callback waits preserve early completion and tolerate late callbacks after timeout or cancellation")
    func callbackWaitLifecycle() async {
        let early = CallbackCompletion()
        early.complete()
        early.complete()
        #expect(await early.wait(timeout: .seconds(2)))

        let timedOut = CallbackCompletion()
        #expect(await timedOut.wait(timeout: .zero) == false)
        timedOut.complete()
        timedOut.complete()

        let cancelled = CallbackCompletion()
        let task = Task { await cancelled.wait(timeout: .seconds(2)) }
        task.cancel()
        #expect(await task.value == false)
        cancelled.complete()
    }

    @Test("A long bubble keeps its scrolled or bounced viewport and dimming silhouette", arguments: [500.0, -20.0])
    func longBubble(offset: Double) async throws {
        let fixture = try Fixture(height: 1300)
        defer { fixture.close() }
        try await fixture.settle()
        let menu = fixture.menu()
        try await fixture.settle(450)
        let scroll = try #require(fixture.content.supernode?.view.superview as? UIScrollView)
        scroll.contentOffset.y = offset
        try await fixture.settle()
        let container = try #require(scroll.superview)
        let dimming = try #require(container.subviews.first)
        let oldBounds = scroll.bounds
        let oldFrame = scroll.frame
        menu.dismissMenu()
        CATransaction.flush()
        let presented = try #require(scroll.layer.presentation())
        #expect(abs(presented.bounds.minY - oldBounds.minY) < 2)
        #expect(abs(presented.bounds.height - oldBounds.height) < 2)
        let mask = try #require(dimming.layer.mask?.presentation())
        #expect(alpha(of: mask, at: CGPoint(x: oldFrame.midX, y: oldFrame.midY)) < 0.02)
        #expect(alpha(of: mask, at: CGPoint(x: oldFrame.minX - 5, y: oldFrame.midY)) > 0.98)
        #expect(alpha(of: mask, at: CGPoint(x: oldFrame.midX, y: oldFrame.minY - 5)) > 0.98)
        if offset < 0 {
            #expect(alpha(of: mask, at: CGPoint(x: oldFrame.midX, y: oldFrame.minY + 5)) > 0.98)
        }

        // Layout of the original Texture parent must not resize extracted
        // content while the menu is returning it through another host.
        let contentBounds = fixture.content.bounds
        fixture.source.bounds.size.height += 10
        fixture.source.layout()
        #expect(fixture.content.bounds == contentBounds)
        fixture.source.bounds.size.height -= 10
        try await fixture.settle(350)
        #expect(fixture.content.supernode === fixture.source)
        #expect(dimming.layer.mask == nil)
    }

    @Test("The dimming hole preserves a media group's square joining corners")
    func partialCorners() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.portal.roundedCorners = [.topLeft, .topRight]
        try await fixture.settle()
        let menu = fixture.menu()
        try await fixture.settle(450)
        let scroll = try #require(fixture.content.supernode?.view.superview as? UIScrollView)
        let dimming = try #require(scroll.superview?.subviews.first)
        let frame = scroll.frame
        menu.dismissMenu()
        CATransaction.flush()
        let mask = try #require(dimming.layer.mask?.presentation())
        #expect(alpha(of: mask, at: CGPoint(x: frame.minX + 1, y: frame.minY + 1)) > 0.98)
        #expect(alpha(of: mask, at: CGPoint(x: frame.minX + 1, y: frame.maxY - 2)) < 0.02)
        try await fixture.settle(350)
    }

    @Test("Real Texture cells supply local outlines independent of shrink and swipe",
          arguments: ["text", "image", "imageTop", "imageMiddle", "imageCaption", "video", "videoCaption",
                      "album", "albumTopCaption", "albumBottomCaption"])
    func cellContours(kind: String) throws {
        let cell = makeCell(kind: kind).node
        let layout = cell.layoutThatFits(ASSizeRange(
            min: CGSize(width: 390, height: 0),
            max: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        ))
        cell.frame = CGRect(origin: .zero, size: layout.size)
        cell.view.layoutIfNeeded()
        let wrapper = cell.contextSourceNode.contentNode
        let path = cell.contextMenuContentPath()
        let rect = path.boundingBoxOfPath
        #expect(rect.width > 50 && rect.height > 20)
        #expect(abs(rect.width - wrapper.bounds.width) < 0.01)
        #expect(abs(rect.height - wrapper.bounds.height) < 0.01)
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        #expect(path.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 1)) == (kind == "imageMiddle"))
        #expect(path.contains(CGPoint(x: rect.minX + 1, y: rect.maxY - 1)) ==
                (kind == "imageTop" || kind == "imageMiddle"))

        wrapper.view.transform = CGAffineTransform(a: 0.92, b: 0, c: 0, d: 0.92, tx: -30, ty: 0)
        #expect(cell.contextMenuContentPath() == path)
    }

    private func makeCell(kind: String, text: String = "A message with its own bubble outline")
        -> (node: MessageCellNode, message: ChatMessage) {
        let caption = kind.hasSuffix("Caption") ? "A caption below the media" : nil
        let content: ChatMessageContent
        if kind.hasPrefix("image") || kind.hasPrefix("album") {
            content = .image(source: nil, thumbnailSource: nil, width: 400, height: 300,
                             caption: caption, previewImageData: nil)
        } else if kind.hasPrefix("video") {
            content = .video(source: nil, thumbnailSource: nil, width: 400, height: 300,
                             duration: 1, filename: "video.mp4", mimetype: nil, size: nil,
                             caption: caption, previewThumbnailData: nil)
        } else {
            content = .text(body: text)
        }
        var message = ChatMessage(
            id: "contour", eventId: nil, transactionId: nil, itemIdentifier: nil,
            senderId: "@alice:example.org", senderDisplayName: nil, senderAvatarUrl: nil,
            isOutgoing: false, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: content, reactions: [], replyInfo: nil, isEditable: false,
            isEdited: false, isEditPending: false, isEditFailed: false, latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(), sendStatus: "synced"
        )
        if kind.hasPrefix("album") {
            message.mediaGroupPresentation = MediaGroupPresentation(
                id: "album", position: .top, totalHint: 4, caption: caption,
                captionPlacement: kind == "albumTopCaption" ? .top : .bottom,
                layoutOverride: nil, suppressIndividualCaption: true,
                items: (0..<4).map { index in
                    MediaGroupItem(
                        messageId: "photo-\(index)", eventId: nil, transactionId: nil,
                        source: nil, thumbnailSource: nil, previewImageData: nil, previewIdentity: nil,
                        width: 400, height: 300, blurhash: nil, sizeBytes: nil,
                        caption: nil, sendStatus: "synced"
                    )
                }, rendersCompositeBubble: true, hidesStandaloneBubble: false
            )
        } else if kind == "imageTop" || kind == "imageMiddle" {
            message.mediaGroupPresentation = MediaGroupPresentation(
                id: "group", position: kind == "imageTop" ? .top : .middle,
                totalHint: 3, caption: nil, captionPlacement: .bottom, layoutOverride: nil,
                suppressIndividualCaption: true, items: [], rendersCompositeBubble: false,
                hidesStandaloneBubble: false
            )
        }
        let cell: MessageCellNode
        if kind.hasPrefix("album") {
            cell = PhotoGroupMessageCellNode(message: message)
        } else {
            switch content {
            case .image: cell = ImageMessageCellNode(message: message)
            case .video: cell = VideoMessageCellNode(message: message)
            default: cell = TextMessageCellNode(message: message)
            }
        }
        return (cell, message)
    }

    @Test("Closing emoji search resigns its responder and returns the key window before hiding")
    func dismissEmojiSearch() async throws {
        let fixture = try Fixture()
        let previousKeyWindow = fixture.window.windowScene?.windows.first { $0.isKeyWindow }
        defer { fixture.close(); previousKeyWindow?.makeKey() }
        fixture.window.makeKey()
        try await fixture.settle()
        let menu = fixture.menu()
        try await fixture.settle(450)
        let menuWindow = try #require(fixture.content.view.window)
        let root = try #require(menuWindow.rootViewController?.view)
        let plus = try #require(descendants(of: root).compactMap { $0 as? UIButton }.first {
            $0.currentTitle == nil && $0.currentImage != nil
        })
        plus.sendActions(for: .touchUpInside)
        try await fixture.settle(350)
        root.layoutIfNeeded()
        // Texture also owns a noninteractive UITextView for the placeholder.
        let search = try #require(descendants(of: root).compactMap { $0 as? UITextView }.first {
            $0.isEditable && $0.isUserInteractionEnabled
        })
        #expect(search.becomeFirstResponder())
        try await fixture.settle()
        #expect(search.isFirstResponder)
        #expect(menuWindow.isKeyWindow)

        menu.dismissMenu()
        #expect(!search.isFirstResponder)
        #expect(!menuWindow.canBecomeKey)
        #expect(fixture.window.isKeyWindow)
        try await fixture.settle(350)
        #expect(menuWindow.isHidden)
        let input = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        fixture.window.rootViewController!.view.addSubview(input)
        #expect(input.becomeFirstResponder())
        input.resignFirstResponder()
    }

    @Test("The dimming hole samples the current outline when dismissal begins")
    func updatedContentOutline() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.settle()
        let menu = fixture.menu()
        try await fixture.settle(450)
        let scroll = try #require(fixture.content.supernode?.view.superview as? UIScrollView)
        let dimming = try #require(scroll.superview?.subviews.first)

        // Simulate media acquiring a new height while extracted. The old
        // viewport now clips through its body, rather than its rounded bottom.
        fixture.source.bounds.size.height += 60
        fixture.content.frame.size.height += 60
        fixture.portal.frame = fixture.content.bounds
        fixture.portal.view.layoutIfNeeded()
        try await fixture.settle()
        let frame = scroll.frame
        menu.dismissMenu()
        CATransaction.flush()
        let mask = try #require(dimming.layer.mask?.presentation())
        #expect(alpha(of: mask, at: CGPoint(x: frame.minX + 1, y: frame.maxY - 2)) < 0.02)
        #expect(alpha(of: mask, at: CGPoint(x: frame.minX + 1, y: frame.minY + 1)) > 0.98)
        try await fixture.settle(350)
        #expect(fixture.content.supernode === fixture.source)
        #expect(fixture.content.frame == fixture.source.bounds)
    }

    @Test("Timeline updates preserve the extracted Texture host and its bubble outline",
          arguments: ["text", "image", "albumBottomCaption", "editedText"])
    func updatesWhileExtracted(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let (cell, message) = makeCell(kind: kind)
        let root = fixture.window.rootViewController!.view!
        let layout = cell.layoutThatFits(ASSizeRange(
            min: CGSize(width: root.bounds.width, height: 0),
            max: CGSize(width: root.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        ))
        cell.frame = CGRect(origin: CGPoint(x: 0, y: 180), size: layout.size)
        root.addSubview(cell.view)
        cell.view.layoutIfNeeded()
        try await fixture.settle()
        let info = try #require(cell.extractBubbleForMenu(in: fixture.window.coordinateSpace))
        let menu = ContextMenuController(
            contentNode: info.node, sourceFrame: info.frame,
            contentPath: { cell.contextMenuContentPath() }, captureView: root,
            actions: [ContextMenuAction(title: "Copy", image: nil, handler: {})]
        )
        menu.onDismissComplete = { cell.restoreBubbleFromMenu() }
        menu.show(in: fixture.window)
        try await fixture.settle(450)
        let host = info.node.supernode
        let bounds = info.node.bounds
        let path = cell.contextMenuContentPath()
        var replacement: MessageCellNode?
        if kind == "editedText" {
            let edited = makeCell(kind: "text", text: String(repeating: "Edited message. ", count: 20))
            #expect(!MessageCellNode.canUpdateInPlace(old: message, new: edited.message))
            let editedLayout = edited.node.layoutThatFits(ASSizeRange(
                min: CGSize(width: root.bounds.width, height: 0),
                max: CGSize(width: root.bounds.width, height: CGFloat.greatestFiniteMagnitude)
            ))
            edited.node.frame = CGRect(origin: cell.frame.origin, size: editedLayout.size)
            cell.view.removeFromSuperview()
            root.addSubview(edited.node.view)
            edited.node.view.layoutIfNeeded()
            replacement = edited.node
        } else {
            cell.updateReactions([MessageReaction(key: "👍", senders: [], isOwn: false, legacyCount: 1)])
            if let album = cell as? PhotoGroupMessageCellNode {
                album.updateMediaGroupPresentation(message.mediaGroupPresentation)
            }
            #expect(cell.reactionsNode != nil)
        }
        cell.view.layoutIfNeeded()
        info.node.view.layoutIfNeeded()
        try await fixture.settle()
        #expect(info.node.supernode === host)
        #expect(info.node.bounds == bounds)
        #expect(cell.contextMenuContentPath() == path)
        let replacementFrame = replacement?.frame
        menu.dismissMenu()
        try await fixture.settle(350)
        #expect(info.node.supernode === cell.contextSourceNode)
        #expect(info.node.frame == cell.contextSourceNode.bounds)
        if let replacement {
            #expect(replacement.view.superview === root)
            #expect(replacement.frame == replacementFrame)
            #expect(replacement.contextSourceNode.contentNode.supernode === replacement.contextSourceNode)
            #expect(cell.view.window == nil)
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test("Dismissal interrupts the entrance spring at its visible geometry")
    func interruptedEntrance() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.content.view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        try await fixture.settle()
        let menu = fixture.menu()
        try await fixture.settle(70)
        let scroll = try #require(fixture.content.supernode?.view.superview as? UIScrollView)
        let oldLayer = try #require(scroll.layer.presentation())
        let menuWindow = try #require(scroll.window)
        let oldFrame = oldLayer.convert(oldLayer.bounds, to: menuWindow.layer.presentation())
        let oldScale = try #require(fixture.content.layer.presentation()).transform.m11
        menu.dismissMenu()
        CATransaction.flush()
        let newLayer = try #require(scroll.layer.presentation())
        let newFrame = newLayer.convert(newLayer.bounds, to: fixture.window.layer.presentation())
        #expect(abs(newFrame.minY - oldFrame.minY) < 2)
        #expect(abs(newFrame.height - oldFrame.height) < 2)
        let newScale = try #require(fixture.content.layer.presentation()).transform.m11
        #expect(abs(newScale - oldScale) < 0.005)
        try await fixture.settle(350)
        #expect(fixture.restorationCount == 1)
        #expect(fixture.content.supernode === fixture.source)
    }

    private func alpha(of layer: CALayer, at point: CGPoint, portalFallback: Bool = false) -> Double {
        // A one-pixel capture verifies the actual renderer/mask, including
        // clipping and ancestor transforms, without allocating full screens.
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: -point.x, y: -point.y)
            if portalFallback {
                BubblePortalCaptureRenderer.renderLayerForCapture(
                    layer, in: ctx, clipRectInLayer: CGRect(origin: point, size: CGSize(width: 1, height: 1))
                )
            } else {
                layer.render(in: ctx)
            }
        }
        return Double(pixel[3]) / 255
    }
}
