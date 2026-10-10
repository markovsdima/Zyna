// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import GRDB
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private let listRoom = "!lists:example.org"

private func listItem(_ index: Int, kind: RoomAttachmentKind = .file) throws -> AttachmentItem {
    let source = try MediaSource.fromUrl(url: "mxc://lists.invalid/attachment")
    return AttachmentItem(id: String(format: "$row%06d", index), uniqueId: "sdk\(index)", kind: kind,
        timestampMs: 1_790_784_000_000 + UInt64(index / 3), sender: "@alice:example.org", senderName: "Alice", isOwn: false,
        filename: "Attachment \(index)", caption: nil, mimetype: "application/octet-stream", sizeBytes: 12_000,
        pixelWidth: nil, pixelHeight: nil, durationSeconds: 60, blurhash: nil, isAnimated: false,
        source: source, sourceMxc: source.url(), isSourceEncrypted: false, thumbnail: nil)
}

private func listDatabase(count: Int, scope: RoomAttachmentCatalogScope) throws -> AccountDatabase {
    let queue = try DatabaseQueue()
    try DatabaseService.migrator.migrate(queue)
    let template = StoredRoomAttachment(roomId: listRoom, item: try listItem(0))
    try queue.write { db in
        for index in 0..<count {
            var record = template
            record.eventId = String(format: "$row%06d", index)
            record.timestampMs += Int64(index / 3)
            record.filename = "Attachment \(index)"
            record.kind = scope == .voice ? "voice" : (index.isMultiple(of: 2) ? "file" : "audio")
            try record.insert(db)
        }
    }
    return AccountDatabase(queue)
}

private final class PagedListSource: AttachmentSource, @unchecked Sendable {
    let paginationAllowed = Atomic(true)
    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)?
    var onPaginationStatus: ((PaginationStatus) -> Void)?
    var onAttachmentsDiscovered: (([StoredRoomAttachment]) -> Void)?
    var onAttachmentsInvalidated: (([String]) -> Void)?
    func start() async throws { onSnapshot?(.empty, .init()) }
    func stop() {}
    func loadMore(numEvents: UInt16) async throws -> Bool {
        while !paginationAllowed.wrappedValue { try await Task.sleep(for: .milliseconds(10)) }
        return true
    }
    func retryDecryption(sessionIds: [String]) {}
    func describeTimelineItem(eventId: String) async -> String? { nil }
    func storeRowDescription(uniqueId: String) -> String? { nil }
}

@Suite("Paged files and voice", .serialized)
@MainActor
struct RoomProfilePagedListTests {
    private func scroll(in view: UIView, scope: RoomAttachmentCatalogScope) -> UIScrollView? {
        let id = scope == .voice ? "profile.voice" : "profile.files"
        if let scroll = view as? UIScrollView, scroll.accessibilityIdentifier == id { return scroll }
        return view.subviews.lazy.compactMap { scroll(in: $0, scope: scope) }.first
    }

    private func wait(_ predicate: () -> Bool, phase: String = "condition") async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "PagedListTestTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: phase])
    }

    @Test("Deep keyset pages use stable ties and reject obsolete snapshots", arguments: [RoomAttachmentCatalogScope.files, .voice])
    func databasePages(scope: RoomAttachmentCatalogScope) async throws {
        let database = try await Task.detached { try listDatabase(count: 100_000, scope: scope) }.value
        defer { try? database.close() }
        let source = RoomMediaDatabase(database: database, roomID: listRoom, scope: scope)
        let snapshot = try await database.read { try source.snapshot(in: $0) }
        #expect(snapshot.count == 100_000)
        #expect(snapshot.order.storageByteCount < 24 * snapshot.count + 8)
        let values = try await source.page(99_000..<99_064, snapshot: snapshot)
        #expect(values.count == 64)
        for index in 99_000..<99_064 { #expect(values[index]?.id == snapshot.order.id(at: index)) }
        let item = try #require(values[99_013])
        #expect(try await source.index(of: item.id, snapshot: snapshot) == 99_013)
        try await database.write { db in
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + RoomMediaDatabase.pageQuery(scope: scope),
                arguments: [listRoom, Int64(clamping: item.timestampMs), item.id, 64]).map { $0["detail"] as String }
            #expect(plan.contains { $0.contains("INDEX \(scope.index)") })
            #expect(plan.contains { $0.contains("(timestampMs,eventId)<(?,?)") })
            #expect(!plan.contains { $0.contains("TEMP B-TREE") })
            try db.execute(sql: "UPDATE roomAttachment SET filename = 'Changed' WHERE eventId = ?", arguments: [item.id])
        }
        let changed = try await database.read { try source.snapshot(in: $0) }
        #expect(changed.orderRevision == snapshot.orderRevision)
        #expect(changed.revision > snapshot.revision)
        await #expect(throws: RoomMediaDatabase.CatalogError.self) { try await source.page(99_000..<99_064, snapshot: snapshot) }
        #expect(try await source.page(99_013..<99_014, snapshot: changed)[99_013]?.filename == "Changed")
    }

    @Test("Visible counts follow kind, metadata, deletion and blocking without catalog projections")
    func counts() async throws {
        let database = try await Task.detached { try listDatabase(count: 30, scope: .files) }.value
        defer { try? database.close() }
        let source = PagedListSource()
        let model = RoomAttachmentsViewModel(roomId: listRoom, source: source, filterMode: .sdkOnlyMessage,
            tilePixelSize: 128, attachmentIndex: RoomAttachmentIndex(roomId: listRoom, dbQueue: database),
            usesPagedMedia: true, usesPagedLists: true)
        defer { model.stop() }
        await model.start()
        try await wait { !model.isInitialLoading && model.currentCount(for: .files) == 30 }
        #expect(model.files.isEmpty && model.voice.isEmpty && model.media.isEmpty)
        try await database.write { db in
            try db.execute(sql: "UPDATE roomAttachment SET kind = 'voice' WHERE eventId = '$row000001'")
            try db.execute(sql: "UPDATE roomAttachment SET senderDisplayName = 'Renamed' WHERE eventId = '$row000002'")
        }
        try await wait { model.currentCount(for: .files) == 29 && model.currentCount(for: .voice) == 1 }
        try await database.write { db in _ = try IgnoredContentStore.replace(["@alice:example.org"], in: db) }
        try await wait { model.currentCount(for: .files) == 0 && model.currentCount(for: .voice) == 0 }
        try await database.write { db in
            try db.execute(sql: "DELETE FROM roomAttachment WHERE eventId = '$row000001'")
            _ = try IgnoredContentStore.replace([], in: db)
        }
        try await wait { model.currentCount(for: .files) == 29 && model.currentCount(for: .voice) == 0 }
        #expect(model.files.isEmpty && model.voice.isEmpty)
    }

    @Test("A large ignored-user replacement recounts each list only once")
    func ignoredBatch() async throws {
        let database = try await Task.detached { try listDatabase(count: 30, scope: .files) }.value
        defer { try? database.close() }
        try await database.write { db in
            try db.execute(sql: "UPDATE roomAttachment SET kind = 'voice' WHERE eventId = '$row000001'")
            let before = try Int.fetchOne(db, sql: "SELECT revision FROM roomAttachmentListRevision WHERE section = 'files'")!
            let blocked = Set((0..<200).map { "@blocked\($0):example.org" }).union(["@alice:example.org"])
            #expect(try IgnoredContentStore.replace(blocked, in: db))
            #expect(try Int.fetchOne(db, sql: "SELECT count FROM roomAttachmentListRevision WHERE section = 'files'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count FROM roomAttachmentListRevision WHERE section = 'voice'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT revision FROM roomAttachmentListRevision WHERE section = 'files'") == before + 1)
            #expect(try !IgnoredContentStore.replace(blocked, in: db))
            #expect(try Int.fetchOne(db, sql: "SELECT revision FROM roomAttachmentListRevision WHERE section = 'files'") == before + 1)
            #expect(try IgnoredContentStore.replace([], in: db))
            #expect(try Int.fetchOne(db, sql: "SELECT count FROM roomAttachmentListRevision WHERE section = 'files'") == 29)
            #expect(try Int.fetchOne(db, sql: "SELECT count FROM roomAttachmentListRevision WHERE section = 'voice'") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT revision FROM roomAttachmentListRevision WHERE section = 'files'") == before + 2)
        }
    }

    @Test("Discovery retains identities and incremental counts without presentation payloads")
    func discovery() throws {
        let store = AttachmentTimelineStore(metadataOnly: true)
        var discovered: [AttachmentItem] = [], removed: [String] = []
        store.onAttachmentsDiscovered = { discovered += $0 }
        store.onAttachmentsInvalidated = { removed += $0 }
        let file = try listItem(1), voice = try listItem(2, kind: .voice), media = try listItem(3, kind: .image)
        store.apply([.reset([.attachment(file), .attachment(voice)]), .pushFront(.attachment(media))])
        #expect(store.currentRows.allSatisfy { $0.attachment == nil })
        #expect(discovered.count == 3)
        #expect(store.currentSnapshot().fileCount == 1 && store.currentSnapshot().voiceCount == 1 && store.currentSnapshot().mediaCount == 1)
        #expect(store.currentSnapshot().files.isEmpty && store.currentSnapshot().voice.isEmpty && store.currentSnapshot().media.isEmpty)
        store.apply([.set(2, .other(uniqueId: voice.uniqueId)), .popFront])
        #expect(removed == [voice.id])
        #expect(store.currentSnapshot().fileCount == 1 && store.currentSnapshot().voiceCount == 0 && store.currentSnapshot().mediaCount == 0)
        store.apply([.clear])
        #expect(store.currentSnapshot().rowCount == 0 && store.currentSnapshot().fileCount == 0)
    }

    @Test("A hundred thousand rows keep viewport nodes and decoded pages bounded through deep scrolling",
          arguments: [RoomAttachmentCatalogScope.files, .voice])
    func boundedList(scope: RoomAttachmentCatalogScope) async throws {
        let database = try await Task.detached { try listDatabase(count: 100_000, scope: scope) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: scope))
        defer { catalog.stop() }
        let page = RoomProfileListPage(voice: scope == .voice, catalog: catalog)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.rootViewController!.view.addSubview(page.view)
        page.collapse = page.headerHeight
        page.isActive = true; page.install()
        page.layout(frame: window.bounds, depth: 0, bottomInset: 34)
        try await wait { catalog.count == 100_000 && page.renderedNodeCount > 2 }
        let height = scope == .voice ? RoomProfileVoiceCell.rowHeight(width: 390) : UIFontMetrics.default.scaledValue(for: 76)
        let geometry = RoomProfileListGeometry(months: catalog.snapshot.months, rowHeight: height,
            headerHeight: UIFontMetrics.default.scaledValue(for: 40))
        for index in [0, 1_000, 5_000, 40_000, 90_000, 99_900, 1_000, 0] {
            page.setPosition(depth: try #require(geometry.frame(at: index, width: 390)).minY + 12)
            try await wait { catalog.item(at: index) != nil }
            #expect(page.renderedNodeCount < 50)
            #expect(catalog.cachedItemCount <= RoomMediaCatalog.maximumPages * RoomMediaCatalog.pageSize)
            #expect(page.captureAnchor()?.id == catalog.snapshot.order.id(at: index))
        }
    }

    @Test("Revision changes restore a visible event and its offset through resize and deletion")
    func anchors() async throws {
        let database = try await Task.detached { try listDatabase(count: 2_000, scope: .files) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: .files))
        defer { catalog.stop() }
        let page = RoomProfileListPage(catalog: catalog)
        page.collapse = page.headerHeight; page.isActive = true; page.install()
        page.layout(frame: CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0, bottomInset: 34)
        try await wait { catalog.count == 2_000 && page.renderedNodeCount > 2 }
        page.setPosition(depth: 40 + 2 + 700 * 78 + 17)
        try await wait { catalog.item(at: 700) != nil }
        let before = try #require(page.captureAnchor())
        try await database.write { db in
            var record = StoredRoomAttachment(roomId: listRoom, item: try listItem(20_000))
            record.timestampMs += 10_000
            try record.insert(db)
        }
        try await wait { catalog.count == 2_001 && page.captureAnchor()?.previousIndex == 701 }
        #expect(page.captureAnchor()?.id == before.id)
        #expect(abs(try #require(page.captureAnchor()).offset - before.offset) < 0.5)
        page.layout(frame: CGRect(x: 0, y: 0, width: 320, height: 700), depth: page.normalizedOffset - page.collapse,
            bottomInset: 34)
        #expect(page.captureAnchor()?.id == before.id)
        #expect(abs(try #require(page.captureAnchor()).offset - before.offset) < 0.5)
        try await database.write { db in try db.execute(sql: "DELETE FROM roomAttachment WHERE eventId = ?", arguments: [before.id]) }
        try await wait { catalog.count == 2_000 && page.captureAnchor()?.id != before.id }
        #expect(page.captureAnchor()?.previousIndex == 701)
        try await database.write { db in try db.execute(sql: "DELETE FROM roomAttachment") }
        try await wait { catalog.count == 0 && page.normalizedOffset <= page.headerHeight + 0.5 }
    }

    @Test("The real voice row stays docked and controllable outside loaded pages")
    func stickyVoice() async throws {
        let database = try await Task.detached { try listDatabase(count: 5_000, scope: .voice) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: .voice))
        defer { catalog.stop() }
        let player = AudioPlayerService(), session = RoomProfileVoiceSession()
        let page = RoomProfileListPage(voice: true, catalog: catalog)
        page.voicePlayback = RoomProfileVoicePlayback(player: player, roomID: listRoom, session: session)
        page.collapse = page.headerHeight; page.isActive = true; page.install()
        page.layout(frame: CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0, bottomInset: 34)
        try await wait { catalog.count == 5_000 && page.renderedNodeCount > 2 }
        let height = RoomProfileVoiceCell.rowHeight(width: 390)
        let geometry = RoomProfileListGeometry(months: catalog.snapshot.months, rowHeight: height, headerHeight: 40)
        page.setPosition(depth: try #require(geometry.frame(at: 2_000, width: 390)).minY + 12)
        try await wait { catalog.item(at: 2_000) != nil }
        let target = try #require(catalog.item(at: 2_000))
        let audio = try await Task.detached { try ProfileVoiceAudioFixture.make() }.value
        defer { player.stop(); page.isActive = false; try? FileManager.default.removeItem(at: audio) }
        player.playLocal(url: audio, sourceKey: target.sourceMxc, nowPlaying: .voice(.init(
            sourceURL: target.sourceMxc, title: "Alice", subtitle: "Room", duration: 60,
            waveform: [], roomId: listRoom, eventId: target.id)))
        player.seek(to: 0.4); player.pause()
        func voices() -> [RoomProfileVoiceCell] {
            func descendants(_ node: ASDisplayNode) -> [ASDisplayNode] {
                (node.subnodes ?? []).flatMap { [$0] + descendants($0) }
            }
            return descendants(page.contentNode).compactMap { $0 as? RoomProfileVoiceCell }.filter { $0.item.id == target.id }
        }
        try await wait { voices().first?.controlsEnabled == true }
        let original = try #require(voices().first)
        let contentSize = page.scrollView.contentSize
        page.setPosition(depth: try #require(geometry.frame(at: 50, width: 390)).minY)
        try await wait { page.bottomDockedPlayerHeight != nil }
        #expect(voices().count == 1 && voices().first === original)
        #expect(page.scrollView.contentSize == contentSize)
        page.setPosition(depth: try #require(geometry.frame(at: 4_000, width: 390)).minY)
        try await wait { catalog.item(at: 4_000) != nil && page.bottomDockedPlayerHeight == nil }
        #expect(voices().count == 1 && voices().first === original && original.controlsEnabled)
        #expect(page.renderedNodeCount < 50)
        original.stopPlayback()
        #expect(player.state == .idle)
        #expect(abs(session.progress(for: target.id) - 0.4) < 0.01)
        try await wait { voices().isEmpty }
    }

    @Test("Interactions defer replacement; an animated return still renders each new viewport")
    func lockedUpdates() async throws {
        let database = try await Task.detached { try listDatabase(count: 120, scope: .files) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: .files))
        defer { catalog.stop() }
        let list = RoomProfilePagedList(catalog: catalog, makeCell: { content in
            {
                #expect(!Thread.isMainThread)
                let row = content.row
                return RoomProfileTextCell(title: row.title, detail: row.detail, isHeader: row.isHeader, isAction: row.isAction)
            }
        })
        list.node.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        list.scrollView.contentInset = UIEdgeInsets(top: 268, left: 0, bottom: 34, right: 0)
        list.layout(rowHeight: 76, headerHeight: 40,
            visibleInsets: UIEdgeInsets(top: 48, left: 0, bottom: 34, right: 0))
        list.onRestoreDepth = { [weak list] in list?.scrollView.contentOffset.y = $0 - 48 }
        list.isActive = true; list.install()
        try await wait { list.snapshot.count == 120 }
        list.scrollView.contentOffset.y = 42 + 50 * 78 + 17 - 48
        list.render()
        let before = try #require(list.captureAnchor())
        list.isLocked = true
        try await database.write { db in
            var record = StoredRoomAttachment(roomId: listRoom, item: try listItem(20_000))
            record.timestampMs += 10_000
            try record.insert(db)
        }
        try await wait { catalog.count == 121 }
        #expect(list.snapshot.count == 120)
        #expect(list.captureAnchor() == before)
        list.isLocked = false
        try await wait { list.snapshot.count == 121 }
        #expect(list.captureAnchor()?.id == before.id)
        #expect(abs(try #require(list.captureAnchor()).offset - before.offset) < 0.5)
        list.isScrollingToBeginning = true
        list.scrollView.contentOffset.y = 42 + 100 * 78 + 17 - 48
        list.render()
        #expect(list.contains(try #require(list.snapshot.order.id(at: 100))))
        let revision = list.snapshot.revision
        try await database.write { db in
            try db.execute(sql: "UPDATE roomAttachment SET filename = 'During animation' WHERE eventId = '$row000050'")
        }
        try await wait { catalog.snapshot.revision > revision }
        #expect(list.snapshot.revision == revision)
        list.isScrollingToBeginning = false
        try await wait { list.snapshot.revision == catalog.snapshot.revision }
    }

    @Test("A failed replacement leaves the displayed anchor intact and retries the same revision")
    func retryRead() async throws {
        let database = try await Task.detached { try listDatabase(count: 120, scope: .files) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: .files))
        defer { catalog.stop() }
        let list = RoomProfilePagedList(catalog: catalog, makeCell: { content in
            {
                let row = content.row
                return RoomProfileTextCell(title: row.title, detail: row.detail, isHeader: row.isHeader, isAction: row.isAction)
            }
        })
        list.node.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        list.layout(rowHeight: 76, headerHeight: 40, visibleInsets: .zero)
        list.isActive = true; list.install()
        try await wait { list.snapshot.count == 120 }
        list.scrollView.contentOffset.y = 42 + 50 * 78 + 17
        list.render()
        let anchor = try #require(list.captureAnchor())
        try await database.write { db in
            // Unchanged order reuses cached IDs/months, then the demanded
            // payload query fails independently of snapshot observation.
            try db.execute(sql: "DROP INDEX idx_roomAttachment_files_order")
            try db.execute(sql: "UPDATE roomAttachment SET filename = 'Changed' WHERE eventId = '$row000050'")
        }
        try await wait { list.error != nil }
        #expect(list.captureAnchor() == anchor)
        try await database.write { db in
            try db.execute(sql: """
                CREATE INDEX idx_roomAttachment_files_order
                ON roomAttachment(roomId, timestampMs DESC, eventId DESC, kind, senderId)
                WHERE kind IN ('file', 'audio')
                """)
        }
        list.retry()
        try await wait { list.snapshot.revision == catalog.snapshot.revision && list.error == nil }
        #expect(list.captureAnchor() == anchor)
    }

    @Test("The production pager restores paged lists after eviction and a catalog insert",
          arguments: [RoomAttachmentCatalogScope.files, .voice])
    func profileEviction(scope: RoomAttachmentCatalogScope) async throws {
        let database = try await Task.detached { try listDatabase(count: 1_000, scope: scope) }.value
        defer { try? database.close() }
        let model = RoomAttachmentsViewModel(roomId: listRoom, source: PagedListSource(), filterMode: .sdkOnlyMessage,
            tilePixelSize: 128, attachmentIndex: RoomAttachmentIndex(roomId: listRoom, dbQueue: database),
            usesPagedMedia: true, usesPagedLists: true)
        let section: RoomProfileScrollState.Section = scope == .voice ? .voice : .files
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: model,
            actions: .none, audioPlayer: AudioPlayerService(), initialSection: section)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let id = scope == .voice ? "profile.voice" : "profile.files"
        func scroll() -> UIScrollView? {
            func find(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, scroll.accessibilityIdentifier == id { return scroll }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(controller.view)
        }
        try await wait {
            guard let scroll = scroll(), let page = scroll.delegate as? RoomProfileListPage else { return false }
            return page.pagedCatalog?.count == 1_000 && scroll.contentSize.height > 10_000 && page.renderedNodeCount > 1
        }
        var page: RoomProfileListPage? = try #require(scroll()?.delegate as? RoomProfileListPage)
        let height = scope == .voice ? RoomProfileVoiceCell.rowHeight(width: 390) : UIFontMetrics.default.scaledValue(for: 76)
        let geometry = RoomProfileListGeometry(months: try #require(page?.pagedCatalog).snapshot.months,
            rowHeight: height, headerHeight: 40)
        scroll()?.contentOffset.y = try #require(geometry.frame(at: 500, width: 390)).minY + 17 - 48
        let anchor = try #require(page?.captureAnchor())
        controller.selectSection(.media, animated: false)
        page = nil
        controller.didReceiveMemoryWarning()
        #expect(scroll() == nil)
        try await database.write { db in
            var record = StoredRoomAttachment(roomId: listRoom, item: try listItem(20_000, kind: scope == .voice ? .voice : .file))
            record.timestampMs += 10_000
            try record.insert(db)
        }
        controller.selectSection(section, animated: false)
        try await wait { (scroll()?.delegate as? RoomProfileListPage)?.captureAnchor()?.previousIndex == 501 }
        page = try #require(scroll()?.delegate as? RoomProfileListPage)
        #expect(page?.captureAnchor()?.id == anchor.id)
        #expect(abs(try #require(page?.captureAnchor()).offset - anchor.offset) < 0.5)
        #expect(scroll()?.panGestureRecognizer.isEnabled == true)
        #expect(page?.renderedNodeCount ?? 100 < 50)
        #expect(model.files.isEmpty && model.voice.isEmpty)
    }

    @Test("Page read errors keep Retry reachable and recover on reactivation at the same revision")
    func ensureErrorFooter() async throws {
        let database = try await Task.detached { try listDatabase(count: 2_000, scope: .files) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: .files))
        let page = RoomProfileListPage(catalog: catalog)
        defer { page.stop() }
        page.collapse = page.headerHeight; page.isActive = true; page.install()
        page.layout(frame: CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0, bottomInset: 34)
        try await wait { catalog.item(at: 0) != nil }
        let height = page.scrollView.contentSize.height
        try await database.write { try $0.execute(sql: "DROP INDEX idx_roomAttachment_files_order") }
        page.setPosition(depth: 42 + 700 * 78)
        try await wait { catalog.error != nil }
        #expect(abs(page.scrollView.contentSize.height - height - UIFontMetrics.default.scaledValue(for: 104)) < 0.5)
        let maximum = page.scrollView.contentSize.height + page.scrollView.contentInset.bottom - page.scrollView.bounds.height
        page.scrollView.contentOffset.y = maximum
        func footer() -> ASDisplayNode? {
            page.contentNode.subnodes?.first { $0.accessibilityLabel?.contains(String(localized: "Try Again")) == true }
        }
        try await wait { footer() != nil }
        #expect(footer()?.frame.intersects(page.scrollView.bounds) == true)
        let revision = catalog.snapshot.revision
        page.isActive = false
        try await database.write { db in
            try db.execute(sql: """
                CREATE INDEX idx_roomAttachment_files_order ON roomAttachment(roomId, timestampMs DESC, eventId DESC, kind, senderId)
                WHERE kind IN ('file', 'audio')
                """)
        }
        page.isActive = true
        try await wait { catalog.error == nil && page.scrollView.contentSize.height == height }
        #expect(catalog.snapshot.revision == revision)
        try await wait { catalog.item(at: 1_999) != nil }
    }

    @Test("Activating an unchanged list keeps its viewport without repeating anchor preparation")
    func unchangedActivation() async throws {
        let database = try await Task.detached { try listDatabase(count: 120, scope: .files) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: .files))
        let list = RoomProfilePagedList(catalog: catalog, makeCell: { _ in { ASCellNode() } })
        defer { list.stop() }
        list.node.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        list.layout(rowHeight: 76, headerHeight: 40, visibleInsets: .zero)
        list.isActive = true; list.install()
        try await wait { list.snapshot.count == 120 }
        list.scrollView.contentOffset.y = 42 + 30 * 78 + 17
        list.render()
        let anchor = try #require(list.captureAnchor())
        var restorations = 0
        list.onRestoreDepth = { [weak list] depth in
            restorations += 1
            list?.scrollView.contentOffset.y = depth
        }
        for _ in 0..<3 {
            list.isActive = false
            list.isActive = true
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(catalog.isObserving)
        #expect(restorations == 0)
        #expect(list.captureAnchor() == anchor)
    }

    @Test("A restarted observation clears its error after a successful unchanged snapshot")
    func observationRecovery() async throws {
        let database = try await Task.detached { try listDatabase(count: 10, scope: .files) }.value
        defer { try? database.close() }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: database, roomID: listRoom, scope: .files))
        defer { catalog.stop() }
        var snapshots = 0, recoveries = 0
        catalog.onSnapshot = { _ in snapshots += 1 }
        catalog.onItemsChanged = { [weak catalog] in
            if let catalog, catalog.error == nil { recoveries += 1 }
        }
        catalog.start()
        try await wait { catalog.count == 10 }
        let before = catalog.snapshot
        catalog.suspend()
        let schema = try await database.write { db in
            let schema = try #require(try String.fetchOne(db, sql:
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'roomAttachmentListRevision'"))
            try db.execute(sql: "CREATE TABLE savedListRevision AS SELECT * FROM roomAttachmentListRevision")
            try db.execute(sql: "DROP TABLE roomAttachmentListRevision")
            return schema
        }
        catalog.start()
        try await wait { catalog.error != nil && !catalog.isObserving }
        try await database.write { db in
            try db.execute(sql: schema)
            try db.execute(sql: "INSERT INTO roomAttachmentListRevision SELECT * FROM savedListRevision")
            try db.execute(sql: "DROP TABLE savedListRevision")
        }
        catalog.start()
        try await wait { catalog.error == nil && catalog.isObserving }
        #expect(catalog.snapshot == before)
        #expect(snapshots == 1)
        #expect(recoveries == 1)
    }

    @Test("Shrinking a hidden paged footer persists the clamped depth across layout and reactivation",
          arguments: [RoomAttachmentCatalogScope.files, .voice])
    func hiddenFooterClamp(scope: RoomAttachmentCatalogScope) async throws {
        let database = try await Task.detached { try listDatabase(count: 30, scope: scope) }.value
        defer { try? database.close() }
        let model = RoomAttachmentsViewModel(roomId: listRoom, source: PagedListSource(), filterMode: .sdkOnlyMessage,
            tilePixelSize: 128, attachmentIndex: RoomAttachmentIndex(roomId: listRoom, dbQueue: database), usesPagedLists: true)
        let section: RoomProfileScrollState.Section = scope == .voice ? .voice : .files
        let controller = RoomProfileViewController(room: nil, title: "Footer clamp", subtitle: "", model: model,
            actions: .none, initialSection: section)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await wait {
            guard let scroll = scroll(in: controller.view, scope: scope),
                  let page = scroll.delegate as? RoomProfileListPage else { return false }
            return page.pagedCatalog?.count == 30 && scroll.contentSize.height > 1_000 && page.renderedNodeCount > 1
        }
        let list = try #require(scroll(in: controller.view, scope: scope))
        let page = try #require(list.delegate as? RoomProfileListPage)
        page.update([RoomProfileRow(id: "footer", title: "Loading", detail: nil, item: nil, isHeader: false, isAction: false)])
        let oldMaximum = list.contentSize.height + list.contentInset.bottom - list.bounds.height
        list.contentOffset.y = oldMaximum
        controller.selectSection(.media, animated: false)
        page.update([RoomProfileRow(id: "footer", title: "", detail: nil, item: nil, isHeader: false, isAction: false)])
        let maximum = list.contentSize.height + list.contentInset.bottom - list.bounds.height
        #expect(abs(oldMaximum - maximum - UIFontMetrics.default.scaledValue(for: 104)) < 0.5)
        #expect(abs(list.contentOffset.y - maximum) < 0.5)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        #expect(abs(list.contentOffset.y - maximum) < 0.5)
        controller.selectSection(section, animated: false)
        #expect(abs(list.contentOffset.y - maximum) < 0.5)
        page.scrollViewWillBeginDragging(list)
        page.scrollViewDidEndDragging(list, willDecelerate: false)
        #expect(abs(list.contentOffset.y - maximum) < 0.5)
    }

    @Test("Short paged sections retain full header collapse through footer changes and locked replay",
          arguments: [RoomAttachmentCatalogScope.files, .voice])
    func shortFooter(scope: RoomAttachmentCatalogScope) async throws {
        let database = try await Task.detached { try listDatabase(count: 2, scope: scope) }.value
        defer { try? database.close() }
        let source = PagedListSource(); source.paginationAllowed.wrappedValue = false
        let model = RoomAttachmentsViewModel(roomId: listRoom, source: source, filterMode: .sdkOnlyMessage,
            tilePixelSize: 128, attachmentIndex: RoomAttachmentIndex(roomId: listRoom, dbQueue: database), usesPagedLists: true)
        let controller = RoomProfileViewController(room: nil, title: "Short room", subtitle: "", model: model,
            actions: .none, mediaCatalog: RoomMediaCatalog(), initialSection: scope == .voice ? .voice : .files)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            source.paginationAllowed.wrappedValue = true
            model.stop(); window.isHidden = true; window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        try await wait({
            guard let page = scroll(in: controller.view, scope: scope)?.delegate as? RoomProfileListPage,
                  page.pagedCatalog?.count == 2, page.renderedNodeCount > 3 else { return false }
            if case .filling = model.fillState { return true }
            return false
        }, phase: "mounted short loading list")
        let list = try #require(scroll(in: controller.view, scope: scope))
        let page = try #require(list.delegate as? RoomProfileListPage)
        let loadingHeight = list.contentSize.height
        list.contentOffset.y = -page.tabsHeight
        source.paginationAllowed.wrappedValue = true
        try await wait({ model.fillState == .exhausted }, phase: "short pagination exhausted")
        try await wait({ list.contentSize.height < loadingHeight }, phase: "short footer disappeared")
        #expect(abs(list.contentOffset.y + page.tabsHeight) < 0.5)
        #expect(abs(list.contentSize.height + list.contentInset.bottom - list.bounds.height + page.tabsHeight) < 0.5)
        page.scrollViewWillBeginDragging(list)
        page.scrollViewDidEndDragging(list, willDecelerate: false)
        #expect(abs(list.contentOffset.y + page.tabsHeight) < 0.5)

        // A footer replacement held during return-to-top must update padding
        // as soon as the page unlocks, even with no pending catalog snapshot.
        page.scrollToBeginning(animated: true)
        page.update([RoomProfileRow(id: "footer", title: "Loading", detail: nil, item: nil, isHeader: false, isAction: false)])
        page.stopScrollingToBeginning()
        try await wait { abs(list.contentSize.height + list.contentInset.bottom - list.bounds.height + page.tabsHeight) < 0.5 }
        controller.selectSection(.media, animated: false)
        controller.selectSection(scope == .voice ? .voice : .files, animated: false)
        #expect(page.pagedCatalog?.isObserving == true)
    }

    @Test("Hidden catalogs skip identity scans, resume current order and stop when a retained controller is popped")
    func catalogLifecycle() async throws {
        let database = try await Task.detached { try listDatabase(count: 200, scope: .files) }.value
        defer { try? database.close() }
        let scans = Atomic(0)
        try await database.read { db in
            db.trace { event in
                if case .statement(let statement) = event, statement.sql.contains("SELECT eventId FROM roomAttachment") {
                    scans.modify { $0 += 1 }
                }
            }
        }
        let model = RoomAttachmentsViewModel(roomId: listRoom, source: PagedListSource(), filterMode: .sdkOnlyMessage,
            tilePixelSize: 128, attachmentIndex: RoomAttachmentIndex(roomId: listRoom, dbQueue: database), usesPagedLists: true)
        let controller = RoomProfileViewController(room: nil, title: "Lifecycle", subtitle: "", model: model,
            actions: .none, initialSection: .files)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.view.frame = host.view.bounds
        controller.didMove(toParent: host)
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await wait { (scroll(in: controller.view, scope: .files)?.delegate as? RoomProfileListPage)?.pagedCatalog?.count == 200 }
        let page = try #require(scroll(in: controller.view, scope: .files)?.delegate as? RoomProfileListPage)
        let catalog = try #require(page.pagedCatalog)
        controller.selectSection(.voice, animated: false)
        try await wait { !catalog.isObserving }
        // Allow the new preview's one-off bootstrap to finish before counting.
        try await Task.sleep(for: .milliseconds(100))
        let before = scans.wrappedValue
        for index in 20_000..<20_004 {
            try await database.write { db in try StoredRoomAttachment(roomId: listRoom, item: listItem(index)).insert(db) }
            try await Task.sleep(for: .milliseconds(220))
        }
        #expect(scans.wrappedValue == before)
        #expect(catalog.count == 200)
        controller.selectSection(.files, animated: false)
        try await wait { catalog.count == 204 && catalog.isObserving }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        #expect(!catalog.isObserving)
        let revision = catalog.snapshot.revision
        try await database.write { db in try StoredRoomAttachment(roomId: listRoom, item: listItem(30_000)).insert(db) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(catalog.snapshot.revision == revision)
        #expect(!catalog.isObserving)
    }

    @Test("The production Voice page keeps one player and clears space for the top button through animated tab changes")
    func pagedVoiceController() async throws {
        let database = try await Task.detached { try listDatabase(count: 5_000, scope: .voice) }.value
        defer { try? database.close() }
        let player = AudioPlayerService()
        let model = RoomAttachmentsViewModel(roomId: listRoom, source: PagedListSource(), filterMode: .sdkOnlyMessage,
            tilePixelSize: 128, attachmentIndex: RoomAttachmentIndex(roomId: listRoom, dbQueue: database), usesPagedLists: true)
        let controller = RoomProfileViewController(room: nil, title: "Voice room", subtitle: "", model: model,
            actions: .none, audioPlayer: player, initialSection: .voice)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { player.stop(); model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await wait { (scroll(in: controller.view, scope: .voice)?.delegate as? RoomProfileListPage)?.pagedCatalog?.count == 5_000 }
        let list = try #require(scroll(in: controller.view, scope: .voice))
        let page = try #require(list.delegate as? RoomProfileListPage)
        let catalog = try #require(page.pagedCatalog)
        let geometry = RoomProfileListGeometry(months: catalog.snapshot.months,
            rowHeight: RoomProfileVoiceCell.rowHeight(width: 390), headerHeight: 40)
        list.contentOffset.y = try #require(geometry.frame(at: 2_000, width: 390)).minY + 12 - page.tabsHeight
        try await wait { catalog.item(at: 2_000) != nil }
        let item = try #require(catalog.item(at: 2_000))
        let audio = try await Task.detached { try ProfileVoiceAudioFixture.make() }.value
        defer { try? FileManager.default.removeItem(at: audio) }
        player.playLocal(url: audio, sourceKey: item.sourceMxc, nowPlaying: .voice(.init(
            sourceURL: item.sourceMxc, title: "Alice", subtitle: "Room", duration: 60,
            waveform: [], roomId: listRoom, eventId: item.id)))
        player.seek(to: 0.4); player.pause()
        func voices() -> [RoomProfileVoiceCell] {
            func descendants(_ node: ASDisplayNode) -> [ASDisplayNode] {
                (node.subnodes ?? []).flatMap { [$0] + descendants($0) }
            }
            return descendants(page.contentNode).compactMap { $0 as? RoomProfileVoiceCell }.filter { $0.item.id == item.id }
        }
        try await wait { voices().first?.controlsEnabled == true }
        let original = try #require(voices().first)
        let contentSize = list.contentSize
        list.contentOffset.y = try #require(geometry.frame(at: 50, width: 390)).minY - page.tabsHeight
        try await wait { page.bottomDockedPlayerHeight != nil }
        func topButton(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "profile.scrollToTop" { return view }
            return view.subviews.lazy.compactMap(topButton).first
        }
        let button = try #require(topButton(controller.view))
        #expect(!button.isHidden)
        #expect(!button.frame.intersects(original.view.convert(original.bounds, to: controller.view)))
        #expect(voices().count == 1 && voices().first === original && list.contentSize == contentSize)
        let anchor = try #require(page.captureAnchor())
        controller.selectSection(.media, animated: true)
        try await wait { !page.isActive && !catalog.isObserving }
        #expect(abs(player.state.progress - 0.4) < 0.01)
        controller.selectSection(.voice, animated: true)
        try await wait { page.isActive && catalog.isObserving && voices().first?.controlsEnabled == true }
        #expect(voices().count == 1 && voices().first === original)
        #expect(page.captureAnchor()?.id == anchor.id)
        #expect(abs(try #require(page.captureAnchor()).offset - anchor.offset) < 0.5)
    }
}
