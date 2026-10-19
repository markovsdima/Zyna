// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import GRDB
import Testing
import UIKit
@testable import Zyna

@Suite("Chat image caption updates", .serialized)
@MainActor
struct ChatImageCaptionTests {
    enum Scenario: CaseIterable {
        case visible, coveredRemoteDeletion, coveredLocalDeletion
    }

    @Test("Caption changes keep the real collection cell, image view and bitmap while updating height",
          arguments: Scenario.allCases)
    func preservesLoadedImage(scenario: Scenario) async throws {
        let covered = scenario != .visible
        var stored = TimelineWriteFixture.message(0)
        stored.contentType = "image"
        stored.contentMediaJSON = #"{"url":"mxc://example.org/photo"}"#
        stored.contentImageWidth = 400
        stored.contentImageHeight = 300
        let queue = try DatabaseQueue()
        try DatabaseService.migrator.migrate(queue)
        let database = AccountDatabase(queue)
        let original = stored
        try await database.write { try original.insert($0) }
        let model = ChatViewModel(testingRoomId: stored.roomId, dbQueue: database,
            window: MessageWindow(roomId: stored.roomId, dbQueue: database),
            includesLocalState: true, mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { chat.finishNavigationSession(); window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        model.prepareInitialHistoryWindow()
        let id = stored.id
        func index() -> IndexPath? {
            model.rows.firstIndex { $0.message?.id == id }.map { IndexPath(row: $0, section: 0) }
        }
        try await ChatBackgroundPresentationTests.wait {
            guard let index = index() else { return false }
            return chat.node.list.nodeForItem(at: index) is ImageMessageCellNode
                && chat.node.list.rectForItem(at: index).height > 0
        }
        let path = try #require(index())
        let rowID = model.rows[path.row].listIdentifier
        let cell = try #require(chat.node.list.nodeForItem(at: path) as? ImageMessageCellNode)
        let imageView = cell.imageNodeView
        func descendants(_ node: ASDisplayNode) -> [ASDisplayNode] {
            [node] + (node.subnodes ?? []).flatMap { descendants($0) }
        }
        let imageNode = try #require(descendants(cell).compactMap { $0 as? RoundedImageNode }.first)
        let imageParent = try #require(imageNode.supernode)
        #expect(imageParent === cell.directBubbleContentNode)
        #expect(cell.bubbleNode.isHidden)
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }
        imageNode.image = bitmap
        let originalHeight = chat.node.list.rectForItem(at: path).height
        #expect(cell.timeNode.attributedText?.string == MessageCellHelpers.timelineTimestampText(
            for: try #require(original.toChatMessage())))
        if covered {
            chat.setNavigationContentVisible(false, prepareWhileHidden: true)
            // The navigation controller detaches the covered route's view.
            chat.view.removeFromSuperview()
        }
        // The first update changes only isEdited, with no caption change.
        for caption: String? in [nil, "Short caption", String(repeating: "Long caption with several lines. ", count: 12), nil, "Again"] {
            try await database.write { db in
                try db.execute(sql: "UPDATE storedMessage SET contentCaption = ?, isEdited = 1 WHERE id = ?",
                               arguments: [caption, id])
            }
            model.refreshPresentationForTesting(.init(setCount: 1))
            try await ChatBackgroundPresentationTests.wait { model.isTimelineRefreshIdleForTesting }
            let currentPath = try #require(index())
            #expect(chat.node.list.nodeForItem(at: currentPath) === cell)
            #expect(cell.imageNodeView === imageView)
            #expect(imageNode.supernode === imageParent)
            #expect(cell.currentImage === bitmap)
            let currentMessage = try #require(model.messages.first { $0.id == id })
            #expect(currentMessage.isEdited)
            #expect(cell.timeNode.attributedText?.string == MessageCellHelpers.timelineTimestampText(for: currentMessage))
            #expect(cell.timeNode.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .white)
            try await ChatBackgroundPresentationTests.wait {
                chat.view.layoutIfNeeded()
                let height = chat.node.list.rectForItem(at: currentPath).height
                return caption == nil ? abs(height - originalHeight) < 1 : height > originalHeight
            }
            if let caption {
                let texts = descendants(cell).compactMap { ($0 as? ASTextNode)?.attributedText?.string }
                #expect(texts.contains(caption.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        if covered {
            let localDeletion = scenario == .coveredLocalDeletion
            if localDeletion { model.registerPendingAnimatedRedactions([id]) }
            var confirmations = 0
            let handleRedaction = model.onRedactedDetected
            model.onRedactedDetected = { batch in
                confirmations += 1
                handleRedaction?(batch)
            }
            try await database.write { db in
                if localDeletion {
                    try PendingRedactionRecord(messageId: id, roomId: original.roomId,
                        itemIdentifier: original.eventId.map { .eventId($0) }).insert(db)
                }
                try db.execute(sql: "UPDATE storedMessage SET contentType = 'redacted' WHERE id = ?", arguments: [id])
            }
            model.refreshPresentationForTesting(.init(setCount: 1, redactedUpsertCount: 1))
            try await ChatBackgroundPresentationTests.wait {
                model.isTimelineRefreshIdleForTesting && index() == nil
                    && !chat.node.list.layout.geometry.ids.contains(rowID)
            }
            #expect(model.messages.isEmpty)
            #expect(confirmations == (localDeletion ? 1 : 0))
            if localDeletion {
                try await model.drainPresentationWorkerForTesting()
                #expect(try await database.read { try PendingRedactionRecord.fetchCount($0) } == 0)
            }
            chat.setNavigationContentVisible(false)
            window.addSubview(chat.view)
            chat.setNavigationContentVisible(true)
            #expect(model.messages.isEmpty)
        }
    }

    @Test("An already edited photo has its edit marker on first display")
    func initialEditMarker() throws {
        var stored = TimelineWriteFixture.message(0)
        stored.contentType = "image"
        stored.isEdited = true
        stored.contentMediaJSON = #"{"url":"mxc://example.org/photo"}"#
        let message = try #require(stored.toChatMessage())
        let cell = ImageMessageCellNode(message: message)
        #expect(cell.timeNode.attributedText?.string == MessageCellHelpers.timelineTimestampText(for: message))
        #expect(cell.timeNode.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .white)
    }

    @Test("Changing the actual image still requires a new cell")
    func newImage() throws {
        var first = TimelineWriteFixture.message(0)
        first.contentType = "image"
        first.contentMediaJSON = #"{"url":"mxc://example.org/first"}"#
        var second = first
        second.contentCaption = "Different photo"
        second.isEdited = true
        second.contentMediaJSON = #"{"url":"mxc://example.org/second"}"#
        #expect(!MessageCellNode.canUpdateInPlace(old: try #require(first.toChatMessage()),
                                                new: try #require(second.toChatMessage())))
    }

    @Test("Confirmed waiting deletion removes the real row without replaying its frozen bubble")
    func waitingDeletionDoesNotReplaySnapshot() async throws {
        let original = TimelineWriteFixture.message(0)
        let queue = try DatabaseQueue()
        try DatabaseService.migrator.migrate(queue)
        let database = AccountDatabase(queue)
        try await database.write { try original.insert($0) }
        let model = ChatViewModel(testingRoomId: original.roomId, dbQueue: database,
            window: MessageWindow(roomId: original.roomId, dbQueue: database), includesLocalState: true, mode: .normal)
        let chat = ChatViewController(viewModel: model, audioPlayer: AudioPlayerService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = chat; window.isHidden = false
        defer { chat.finishNavigationSession(); window.isHidden = true; window.rootViewController = nil }
        chat.view.layoutIfNeeded()
        model.prepareInitialHistoryWindow()
        try await ChatBackgroundPresentationTests.wait {
            chat.node.list.layout.geometry.ids.contains("message:\(original.id)")
                || chat.node.list.indexPathsForVisibleItems().contains {
                    (chat.node.list.nodeForItem(at: $0) as? MessageCellNode)?.messageId == original.id
                }
        }
        try #require(chat.prepareLocalDeletionForTesting(original.id))
        try await database.write { db in
            try PendingRedactionRecord(messageId: original.id, roomId: original.roomId,
                itemIdentifier: .eventId(original.eventId!), createdAt: Date().timeIntervalSince1970 - 3).insert(db)
        }
        model.refreshPresentationForTesting(.init(requiresPresentationRefresh: true))
        try await ChatBackgroundPresentationTests.wait {
            model.messages.first?.id == "pending-redaction:\(original.id)"
                && model.isTimelineRefreshIdleForTesting
        }
        try await database.write {
            try $0.execute(sql: "UPDATE storedMessage SET contentType = 'redacted', contentBody = NULL")
        }
        model.refreshPresentationForTesting(.init(setCount: 1, redactedUpsertCount: 1))
        try await ChatBackgroundPresentationTests.wait {
            model.isTimelineRefreshIdleForTesting && model.messages.isEmpty && chat.node.list.layout.geometry.ids.isEmpty
        }
        // A frozen splash starts after its 80 ms anticipation animation.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!(chat.node.paintSplashHostView.layer.sublayers ?? []).contains { $0 is PaintSplashLayer })
        #expect(chat.node.list.committedVisiblePaths.isEmpty)
    }
}
