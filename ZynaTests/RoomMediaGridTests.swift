// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import GRDB
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private func mediaFixture(_ index: Int) throws -> AttachmentItem {
    let source = try MediaSource.fromUrl(url: "mxc://grid.invalid/\(index)")
    // Distinct, cheap solid-color placeholders make crossfades inspectable.
    let color = ((index * 67 % 190 + 50) << 16) | ((index * 103 % 190 + 50) << 8) | (index * 43 % 190 + 50)
    let hash = "00" + String([571_787, 6_889, 83, 1].map { Blurhash.base83Characters[(color / $0) % 83] })
    return AttachmentItem(id: String(format: "$photo%06d", index), uniqueId: "sdk\(index)", kind: .image,
        timestampMs: 1_790_784_000_000 + UInt64(index / 3), sender: "@a:example.org", senderName: "Alice", isOwn: false,
        filename: "Photo \(index)", caption: nil, mimetype: "image/jpeg", sizeBytes: nil, pixelWidth: 300, pixelHeight: 300,
        durationSeconds: nil, blurhash: hash, isAnimated: false,
        source: source, sourceMxc: source.url(), isSourceEncrypted: true, thumbnail: nil)
}

private func mediaDatabase(count: Int) throws -> AccountDatabase {
    let queue = try DatabaseQueue()
    try DatabaseService.migrator.migrate(queue)
    let template = StoredRoomAttachment(roomId: "!grid:example.org", item: try mediaFixture(0))
    try queue.write { db in
        for i in 0..<count {
            var record = template
            record.eventId = String(format: "$photo%06d", i)
            record.timestampMs += Int64(i / 3)
            try record.insert(db)
        }
    }
    return AccountDatabase(queue)
}

@Suite("Paged media catalog")
struct RoomMediaCatalogTests {
    @Test("Pages and anchors agree across timestamp ties; a changed revision rejects stale pages")
    func revisions() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 2048) }.value
        let source = RoomMediaDatabase(database: db, roomID: "!grid:example.org")
        let snapshot = try await db.read { try source.snapshot(in: $0) }
        #expect(snapshot.count == 2048)
        #expect(snapshot.months.count == 1)
        let page = try await source.page(768..<832, snapshot: snapshot)
        #expect(page.count == 64)
        let anchor = try #require(page[800])
        #expect(try await source.index(of: anchor.id, snapshot: snapshot) == 800)
        try await db.write { db in
            try db.execute(sql: "UPDATE roomAttachment SET caption = 'edited' WHERE roomId = ? AND eventId = ?",
                           arguments: ["!grid:example.org", anchor.id])
        }
        await #expect(throws: RoomMediaDatabase.CatalogError.self) {
            try await source.page(768..<832, snapshot: snapshot)
        }
        let updated = try await db.read { try source.snapshot(in: $0) }
        #expect(updated.revision > snapshot.revision)
        #expect(try await source.page(800..<801, snapshot: updated)[800]?.caption == "edited")
        try await db.write { db in
            try db.execute(sql: "DELETE FROM roomAttachment WHERE roomId = ? AND eventId = ?", arguments: ["!grid:example.org", anchor.id])
        }
        let deleted = try await db.read { try source.snapshot(in: $0) }
        #expect(deleted.count == 2047)
        #expect(try await source.index(of: anchor.id, snapshot: deleted) == nil)
        try await Task.detached { try db.close() }.value
        await #expect(throws: AccountDatabase.AccessError.self) { try await source.page(0..<1, snapshot: deleted) }
    }

    @Test("Month titles use Gregorian boundaries even with a non-Gregorian preferred calendar")
    func calendarTitles() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 2) }.value
        try await db.write { db in
            try db.execute(sql: "UPDATE roomAttachment SET timestampMs = CASE eventId WHEN '$photo000000' THEN 1705752000000 ELSE 1707134400000 END")
        }
        let source = RoomMediaDatabase(database: db, roomID: "!grid:example.org")
        let now = Date(timeIntervalSince1970: 1_708_430_400) // February 20, 2024.
        let snapshot = try await db.read { try source.snapshot(in: $0, now: now, locale: Locale(identifier: "en_US@calendar=hebrew")) }
        #expect(snapshot.months.map(\.id) == ["2024-02", "2024-01"])
        #expect(snapshot.months.first?.title == String(localized: "This Month"))
        #expect(snapshot.months.last?.title == "January 2024")
        let later = try await db.read { try source.snapshot(in: $0, now: now.addingTimeInterval(40 * 86400), locale: Locale(identifier: "en_US")) }
        #expect(later.revision == snapshot.revision)
        #expect(later.months.first?.title == "February 2024")
        let russian = try await db.read { try source.snapshot(in: $0, now: now.addingTimeInterval(40 * 86400), locale: Locale(identifier: "ru_RU")) }
        let title = try #require(russian.months.last?.title)
        #expect(title.hasPrefix("Январь 2024"))
        #expect(title.contains("г."))
        #expect(!title.contains("Г."))

        try await Task.detached { try db.close() }.value
    }

    @Test("Month ranges honor timezone and DST boundaries and skip empty months")
    func monthRanges() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 5) }.value
        let parser = ISO8601DateFormatter()
        let dates = ["2024-03-01T00:30:00Z", "2024-03-01T08:00:00Z", "2024-04-01T06:59:59Z", "2024-04-01T07:00:00Z", "2024-06-01T08:00:00Z"]
            .map { Int64(parser.date(from: $0)!.timeIntervalSince1970 * 1000) }
        try await db.write { db in
            for (index, timestamp) in dates.enumerated() {
                try db.execute(sql: "UPDATE roomAttachment SET timestampMs = ? WHERE eventId = ?",
                    arguments: [timestamp, String(format: "$photo%06d", index)])
            }
        }
        let source = RoomMediaDatabase(database: db, roomID: "!grid:example.org")
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let local = try await db.read { try source.snapshot(in: $0, timeZone: losAngeles) }
        #expect(local.months.map(\.id) == ["2024-06", "2024-04", "2024-03", "2024-02"])
        #expect(local.months.map(\.count) == [1, 1, 2, 1])
        let utc = try await db.read { try source.snapshot(in: $0, timeZone: TimeZone(secondsFromGMT: 0)!) }
        #expect(utc.months.map(\.id) == ["2024-06", "2024-04", "2024-03"])
        #expect(utc.months.map(\.count) == [1, 2, 2])
        #expect(utc.revision == local.revision)
        let page = try await source.page(0..<5, snapshot: local)
        #expect(page.count == 5)
        for index in 0..<5 { #expect(page[index]?.id == local.order.id(at: index)) }
        try await Task.detached { try db.close() }.value
    }

    @Test("The visual identity and month queries use the covering index without sorting")
    func coveringIndex() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 9) }.value
        try await db.read { db in
            let identityPlan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + RoomMediaDatabase.identityQuery,
                arguments: ["!grid:example.org"]).map { $0["detail"] as String }
            #expect(identityPlan.contains { $0.contains("COVERING INDEX idx_roomAttachment_visual_order") })
            #expect(!identityPlan.contains { $0.contains("TEMP B-TREE") })
            let monthPlan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + RoomMediaDatabase.monthCountQuery,
                arguments: ["!grid:example.org", 0, Int64.max]).map { $0["detail"] as String }
            #expect(monthPlan.contains { $0.contains("COVERING INDEX idx_roomAttachment_visual_order") })
            #expect(!monthPlan.contains { $0.contains("TEMP B-TREE") })
        }
        try await Task.detached { try db.close() }.value
    }

    @MainActor
    @Test("Queued discovery revisions coalesce independently of month count; cancellation drops scheduled reads", arguments: [1, 3])
    func coalescedDiscovery(monthCount: Int) async throws {
        let db = try await Task.detached { try mediaDatabase(count: 100) }.value
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Mid-month dates keep the fixture independent of the local time zone.
        let timestamps = (1...monthCount).map { month in
            Int64(calendar.date(from: DateComponents(year: 2024, month: month, day: 15))!.timeIntervalSince1970 * 1000)
        }
        func discoveredRecord(_ index: Int) throws -> StoredRoomAttachment {
            var record = try StoredRoomAttachment(roomId: "!grid:example.org", item: mediaFixture(index))
            record.timestampMs = timestamps[index % monthCount] + Int64(index)
            return record
        }
        try await db.write { db in
            let records = try StoredRoomAttachment.fetchAll(db)
            for (index, record) in records.enumerated() {
                var updated = record
                updated.timestampMs = timestamps[index % monthCount] + Int64(index)
                try updated.update(db)
            }
        }
        let delivery = DispatchQueue(label: "test.media.discovery")
        let source = RoomMediaDatabase(database: db, roomID: "!grid:example.org", queue: delivery)
        let rebuilds = Atomic(0)
        try await db.read { db in
            db.trace { event in
                // One full identity scan per rebuild, regardless of how many
                // occupied months require their own range-count queries.
                if case let .statement(statement) = event, statement.sql == RoomMediaDatabase.identityQuery {
                    rebuilds.modify { $0 += 1 }
                }
            }
        }
        let snapshots = Atomic([RoomMediaSnapshot]())
        let token = source.observe(onError: { Issue.record($0) }, onChange: { value in snapshots.modify { $0.append(value) } })
        defer { token.cancel() }
        try await ChatBackgroundPresentationTests.wait { snapshots.wrappedValue.count == 1 }
        #expect(snapshots.wrappedValue.first?.months.count == monthCount)
        #expect(rebuilds.wrappedValue == 1)
        let gate = DispatchSemaphore(value: 0)
        let entered = Atomic(false)
        delivery.async { entered.wrappedValue = true; _ = gate.wait(timeout: .now() + 8) }
        defer { gate.signal() }
        try await ChatBackgroundPresentationTests.wait { entered.wrappedValue }
        for i in 100..<112 {
            let record = try discoveredRecord(i)
            try await db.write { try record.insert($0) }
        }
        gate.signal()
        try await ChatBackgroundPresentationTests.wait { snapshots.wrappedValue.last?.count == 112 }
        // Drain queued revision callbacks before observing the read count.
        await withCheckedContinuation { continuation in delivery.async { continuation.resume() } }
        #expect(rebuilds.wrappedValue == 2)
        #expect(snapshots.wrappedValue.count == 2)
        #expect(snapshots.wrappedValue.last?.months.count == monthCount)
        let record = try discoveredRecord(112)
        try await db.write { try record.insert($0) }
        token.cancel()
        // This is a negative check: let the throttle deadline elapse.
        try await Task.sleep(for: .milliseconds(300))
        #expect(rebuilds.wrappedValue == 2)
        #expect(snapshots.wrappedValue.count == 2)
        try await Task.detached { try db.close() }.value
    }

    @Test("One hundred thousand identities stay compact and remain valid after insertion")
    func largeIdentitySnapshot() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 100_000) }.value
        let source = RoomMediaDatabase(database: db, roomID: "!grid:example.org")
        let snapshot = try await db.read { try source.snapshot(in: $0) }
        #expect(snapshot.order.count == 100_000)
        #expect(snapshot.order.storageByteCount < 3_000_000)
        #expect(snapshot.order.id(at: 90_000) == "$photo009999")

        let inserted = try StoredRoomAttachment(roomId: "!grid:example.org", item: mediaFixture(100_000))
        try await db.write { try inserted.insert($0) }
        let next = try await db.read { try source.snapshot(in: $0) }
        #expect(snapshot.order.id(at: 90_000) == "$photo009999")
        #expect(next.order.id(at: 90_001) == "$photo009999")
        try await Task.detached { try db.close() }.value
    }

    @Test("The image viewer requests one neighbor by stable cursor, including after a deletion")
    func gallery() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 100) }.value
        let source = RoomMediaDatabase(database: db, roomID: "!grid:example.org")
        let first = try await source.galleryPage(item: mediaFixture(99), frame: .zero)
        #expect(first.index == 0 && first.count == 100)
        let counts = Atomic(0)
        try await db.read { db in
            db.trace { event in
                if event.description.contains("SELECT COUNT(*)") { counts.modify { $0 += 1 } }
            }
        }
        let next = try #require(try await source.adjacent(to: first, direction: 1))
        #expect(next.eventId == "$photo000098")
        #expect(next.index == 1)
        let previous = try #require(try await source.adjacent(to: next, direction: -1))
        #expect(previous.eventId == first.eventId && previous.index == 0 && previous.count == 100)
        #expect(counts.wrappedValue == 0)
        // Metadata does not change ordering or invalidate the cached counter.
        try await db.write { try $0.execute(sql: "UPDATE roomAttachment SET caption = 'edited' WHERE eventId = '$photo000099'") }
        #expect(try await source.adjacent(to: next, direction: -1)?.catalogRevision == first.catalogRevision)
        #expect(counts.wrappedValue == 0)
        #expect(try await source.adjacent(to: first, direction: -1) == nil)
        try await db.write { db in
            try db.execute(sql: "DELETE FROM roomAttachment WHERE eventId = ?", arguments: [next.eventId])
        }
        let after = try #require(try await source.adjacent(to: next, direction: 1))
        #expect(after.eventId == "$photo000097")
        #expect(after.count == 99 && after.index == 1)
        #expect(counts.wrappedValue == 2)
        let inserted = try StoredRoomAttachment(roomId: "!grid:example.org", item: mediaFixture(100))
        try await db.write { try inserted.insert($0) }
        let newer = try #require(try await source.adjacent(to: after, direction: -1))
        #expect(newer.eventId == first.eventId && newer.count == 100 && newer.index == 1)
        #expect(counts.wrappedValue == 4)
        try await Task.detached { try db.close() }.value
    }

    @MainActor
    @Test("Decoded record cache stays bounded while visiting a large indexed catalog")
    func boundedCache() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 4096) }.value
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: db, roomID: "!grid:example.org"))
        catalog.start()
        defer { catalog.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while catalog.count != 4096, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(catalog.count == 4096)
        for offset in stride(from: 0, to: 4096, by: 256) {
            try await catalog.prepare(offset..<(offset + 256), in: catalog.snapshot)
            #expect(catalog.cachedItemCount <= RoomMediaCatalog.maximumPages * RoomMediaCatalog.pageSize)
            #expect(catalog.item(at: offset) != nil)
        }
        #expect(catalog.item(at: 0) == nil)
        catalog.stop()
        #expect(catalog.cachedItemCount == 0)
        try await Task.detached { try db.close() }.value
    }
}

@Suite("Media geometry")
struct RoomMediaGeometryTests {
    @Test("Two photos in an incomplete month row are adjacent and left-aligned at every width")
    func shortRows() throws {
        let months = [RoomMediaMonth(id: "a", title: "A", count: 5, newest: 2, oldest: 1),
                      RoomMediaMonth(id: "b", title: "B", count: 4, newest: 0, oldest: 0)]
        for width: CGFloat in [320, 402, 700] {
            let geometry = RoomMediaGeometry(months: months, width: width, columns: 3, scale: 3)
            let first = try #require(geometry.frame(at: 3)), second = try #require(geometry.frame(at: 4))
            #expect(first.minX == 0 && second.minY == first.minY)
            #expect(abs(second.minX - first.maxX - 2) < 0.5)
            #expect(geometry.frame(at: 5)?.minX == 0)
            #expect(geometry.frame(at: 8)?.minX == 0)
            #expect(geometry.index(at: CGPoint(x: second.midX, y: second.midY)) == 4)
            #expect(geometry.index(at: CGPoint(x: width - 10, y: second.midY)) == nil)
        }
    }

    @Test("Two through ten columns preserve month boundaries and point lookup")
    func layouts() throws {
        let months = [RoomMediaMonth(id: "a", title: "A", count: 100_003, newest: 2, oldest: 1),
                      RoomMediaMonth(id: "b", title: "B", count: 27, newest: 0, oldest: 0)]
        for columns in 2...10 {
            let geometry = RoomMediaGeometry(months: months, width: 402, columns: columns, scale: 3)
            for index in [0, 1, 12, 90_000, 100_002, 100_003, 100_029] {
                let frame = try #require(geometry.frame(at: index))
                #expect(geometry.index(at: CGPoint(x: frame.midX, y: frame.midY)) == index)
                #expect(geometry.range(in: frame).contains(index))
                #expect(frame.minX >= 0 && frame.maxX <= 402)
            }
            #expect(geometry.frame(at: 100_003)?.minX == 0)
            let viewport = CGRect(x: 0, y: try #require(geometry.frame(at: 90_000)).minY, width: 402, height: 874)
            #expect(geometry.range(in: viewport).count < 300)
        }
    }
}

@Suite("Layer media grid", .serialized)
@MainActor
struct RoomMediaGridTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    @Test("An unloaded viewport anchors to the old revision when new media is inserted")
    func unloadedAnchor() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 4096) }.value
        let source = RoomMediaDatabase(database: db, roomID: "!grid:example.org")
        let catalog = RoomMediaCatalog(source: source)
        let grid = RoomMediaGrid(catalog: catalog)
        grid.install(); grid.isActive = true; grid.collapse = grid.headerHeight
        grid.layout(frame: CGRect(x: 0, y: 0, width: 402, height: 874), depth: 0, bottomInset: 0)
        defer { catalog.stop() }
        try await wait { grid.geometry?.count == 4096 }
        let records = try await Task.detached {
            try (4096..<4099).map { try StoredRoomAttachment(roomId: "!grid:example.org", item: mediaFixture($0)) }
        }.value
        let gate = DispatchSemaphore(value: 0)
        let entered = Atomic(false)
        let writer = Task.detached {
            try await db.write { db in
                for record in records { try record.insert(db) }
                entered.wrappedValue = true
                _ = gate.wait(timeout: .now() + 8)
            }
        }
        defer { gate.signal() }
        try await wait { entered.wrappedValue }
        grid.setPosition(depth: 90_000)
        let anchor = try #require(grid.captureAnchor())
        #expect(grid.loadedItem(at: anchor.previousIndex) == nil)
        #expect(catalog.item(at: anchor.previousIndex) == nil)
        gate.signal()
        try await writer.value
        try await wait { grid.geometry?.count == 4099 }
        let restored = try #require(grid.captureAnchor())
        #expect(restored.id == anchor.id)
        #expect(restored.previousIndex == anchor.previousIndex + 3)
        #expect(abs(restored.offset - anchor.offset) < 1)
        #expect(catalog.cachedItemCount <= RoomMediaCatalog.maximumPages * RoomMediaCatalog.pageSize)
        catalog.stop()
        try await Task.detached { try db.close() }.value
    }

    @Test("A calendar refresh changes visible month labels without evicting loaded records")
    func calendarRefresh() async throws {
        let db = try await Task.detached { try mediaDatabase(count: 9) }.value
        let now = Date()
        try await db.write { try $0.execute(sql: "UPDATE roomAttachment SET timestampMs = ?", arguments: [Int64(now.timeIntervalSince1970 * 1000)]) }
        let catalog = RoomMediaCatalog(source: RoomMediaDatabase(database: db, roomID: "!grid:example.org"))
        let grid = RoomMediaGrid(catalog: catalog)
        grid.install(); grid.isActive = true
        grid.layout(frame: CGRect(x: 0, y: 0, width: 402, height: 874), depth: 0, bottomInset: 0)
        defer { catalog.stop() }
        try await wait { grid.geometry?.count == 9 }
        let label = try #require(grid.node.subnodes?.compactMap { $0 as? ASTextNode }.first { $0.attributedText?.string == String(localized: "This Month") })
        let revision = catalog.snapshot.revision
        let cached = catalog.cachedItemCount
        catalog.refresh(now: now.addingTimeInterval(40 * 86400))
        try await wait { label.attributedText?.string != String(localized: "This Month") }
        #expect(catalog.snapshot.revision == revision)
        #expect(catalog.cachedItemCount == cached)
        catalog.stop()
        try await Task.detached { try db.close() }.value
    }

    @Test("Pinch keeps its starting edge fixed across 2–10 columns and preserves vertical position",
          arguments: [0.25, 0.75])
    func zoomAndMutation(horizontalFraction: Double) async throws {
        let items = try await Task.detached { try (0..<2000).map(mediaFixture) }.value
        let catalog = RoomMediaCatalog()
        let grid = RoomMediaGrid(catalog: catalog)
        let host = ASDKViewController(node: ASDisplayNode())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.isHidden = false
        defer { grid.dismissContextMenu(); catalog.stop(); window.isHidden = true; window.rootViewController = nil }
        host.node.addSubnode(grid.node)
        grid.install(); grid.isActive = true; grid.collapse = grid.headerHeight
        grid.layout(frame: host.view.bounds, depth: 0, bottomInset: 0)
        catalog.replace(groups: [.init(id: "month", title: "September", items: items)])
        try await wait { grid.geometry?.count == 2000 }
        grid.beginZoom(at: CGPoint(x: 180, y: 100))
        grid.updateZoom(to: 3.5)
        let monthLabels = (grid.node.subnodes ?? []).flatMap { $0.subnodes ?? [] }
            .compactMap { $0 as? ASTextNode }.filter { $0.attributedText?.string == "September" }
        #expect(monthLabels.count == 2)
        try await wait { monthLabels.allSatisfy { $0.layer.contents != nil } }
        grid.endZoom(cancelled: true, animated: false)
        grid.setPosition(depth: 9000)
        let point = CGPoint(x: grid.view.bounds.width * horizontalFraction, y: 400)
        let contentPoint = CGPoint(x: point.x, y: point.y + grid.scrollView.contentOffset.y)
        let initial = try #require(grid.geometry)
        let index = try #require(initial.index(at: contentPoint, nearest: true))
        let frame = try #require(initial.frame(at: index))
        let unitY = min(1, max(0, (contentPoint.y - frame.minY) / frame.height))
        grid.beginZoom(at: point)
        for density in [3.2, 3.5, 3.8, 3.9999, 4, 4.0001, 4.8, 7.1, 9.9, 10, 6.4, 2.0, 3.0] {
            grid.updateZoom(to: density)
            let moved = try #require(grid.displayedFrame(at: index))
            #expect(abs(moved.minY + moved.height * unitY - grid.scrollView.contentOffset.y - point.y) < 1)
            #expect(grid.renderedTileCount < 600)
            #expect(grid.retainedTileCount < 1000)
            let presentations = grid.zoomPresentations(at: index)
            #expect(presentations.count == (density.rounded(.down) == density ? 1 : 2))
            for presentation in presentations {
                let native = RoomMediaGeometry(months: catalog.snapshot.months, width: initial.width,
                    columns: presentation.columns, scale: window.screen.scale)
                let nativeAnchor = try #require(native.frame(at: index))
                let nativeNeighbor = try #require(native.frame(at: index + 1))
                let neighbor = try #require(grid.zoomPresentations(at: index + 1).first { $0.columns == presentation.columns })
                // Every relative position is a rigid grid scaled as a whole,
                // including a neighbor that wraps onto the following row.
                #expect(abs((neighbor.frame.minX - presentation.frame.minX) / presentation.frame.width
                    - (nativeNeighbor.minX - nativeAnchor.minX) / native.side) < 0.001)
                #expect(abs((neighbor.frame.minY - presentation.frame.minY) / presentation.frame.height
                    - (nativeNeighbor.minY - nativeAnchor.minY) / native.side) < 0.001)
                // Reconstruct the visible plane's edges from any tile.
                // Keeping this photo under the fingers horizontally would
                // break this invariant whenever its column changes.
                let scale = presentation.frame.width / native.side
                let left = presentation.frame.minX - nativeAnchor.minX * scale
                let right = left + native.width * scale
                #expect(abs(horizontalFraction < 0.5 ? left : right - native.width) < 0.001)
                if density.rounded(.down) == density {
                    #expect(abs(presentation.frame.minX - nativeAnchor.minX) < 0.001)
                    #expect(abs(presentation.frame.width - nativeAnchor.width) < 0.001)
                }
                #expect(abs(presentation.frame.minY + presentation.frame.height * unitY - grid.scrollView.contentOffset.y - point.y) < 1)
                #expect(presentation.opacity > 0 && presentation.opacity <= 1)
            }
        }
        grid.endZoom(cancelled: true, animated: false)
        #expect(grid.columns == 3)
        #expect(grid.zoomPresentations(at: index).isEmpty)
        #expect(grid.retainedTileCount == grid.renderedTileCount)
        #expect(abs(grid.scrollView.contentOffset.y - (9000 - 48)) < 1)

        grid.beginZoom(at: point)
        grid.updateZoom(to: 10)
        catalog.replace(groups: [.init(id: "month", title: "September", items: [try mediaFixture(9000)] + items)])
        #expect(grid.geometry?.count == 2000)
        grid.endZoom(cancelled: false, animated: false)
        try await wait { grid.geometry?.count == 2001 }
        #expect(grid.columns == 10)
        #expect(grid.renderedTileCount < 600)
        let anchor = try #require(grid.captureAnchor())
        grid.layout(frame: CGRect(x: 0, y: 0, width: 700, height: 380), depth: grid.normalizedOffset - grid.collapse, bottomInset: 0)
        try await wait { grid.geometry?.width == 700 }
        #expect(grid.captureAnchor()?.id == anchor.id)
        #expect(abs((grid.captureAnchor()?.offset ?? 0) - anchor.offset) < 1)

        // Accessibility uses the same animated transition, with a partially
        // expanded header held still, then an empty catalog clamps its depth.
        grid.collapse = 80
        grid.setColumns(2, animated: true)
        try await wait { !grid.isZooming }
        #expect(grid.columns == 2 && grid.collapse == 80)
        catalog.replace(groups: [])
        try await wait { grid.geometry?.count == 0 }
        #expect(abs(grid.normalizedOffset - 80) < 1)
    }

    @Test("Media menu transfers the live image layer without a repaint or fade, then applies pending data")
    func menu() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host; window.isHidden = false
        let catalog = RoomMediaCatalog()
        let grid = RoomMediaGrid(catalog: catalog)
        defer { grid.dismissContextMenu(); catalog.stop(); window.isHidden = true; window.rootViewController = nil }
        host.view.addSubview(grid.view); grid.install(); grid.isActive = true; grid.collapse = grid.headerHeight
        grid.layout(frame: host.view.bounds, depth: 0, bottomInset: 0)
        let items = try (0..<3).map(mediaFixture)
        grid.update(RoomProfileRow.rows(groups: [.init(id: "month", title: "September", items: items)]) + [
            RoomProfileRow(id: "footer", title: "More media", detail: nil, item: nil, isHeader: false, isAction: true)
        ])
        try await wait { grid.geometry?.count == 3 && grid.loadedItem(at: 0) != nil }
        grid.beginZoom(at: CGPoint(x: 180, y: 100)); grid.updateZoom(to: 2.5)
        let footers = (grid.node.subnodes ?? []).flatMap { $0.subnodes ?? [] }
            .compactMap { $0 as? ASTextNode }.filter { $0.attributedText?.string == "More media" }
        try #require(footers.count == 2)
        try await wait { footers.allSatisfy { $0.layer.contents != nil } }
        grid.endZoom(cancelled: true, animated: false)
        var selected: String?
        grid.onShowInChat = { selected = $0.id }
        let layers = grid.view.layer.sublayers?.compactMap { $0 as? RoomMediaTileLayer } ?? []
        let lifted = try #require(layers.first { $0.item?.id == items[0].id })
        try await wait { lifted.contents != nil }
        let pixels = try #require(lifted.image?.cgImage)
        let sourceFrame = lifted.frame
        grid.presentMenu(at: 0)
        #expect(!grid.scrollView.isScrollEnabled)
        func isInside(_ layer: CALayer, _ ancestor: CALayer) -> Bool {
            var current: CALayer? = layer
            while let value = current {
                if value === ancestor { return true }
                current = value.superlayer
            }
            return false
        }
        // Search may have left UIKit's text effects window in the scene.
        // Select the overlay that actually owns the extracted image layer.
        func menuWindow() throws -> UIWindow {
            try #require(scene.windows.first {
                $0 !== window && $0.windowLevel > window.windowLevel && !$0.isHidden && isInside(lifted, $0.layer)
            })
        }
        let overlay = try menuWindow()
        // Check synchronously, before an async Texture draw can complete.
        #expect(isInside(lifted, overlay.layer))
        #expect((lifted.contents as AnyObject?) === pixels)
        #expect(lifted.opacity == 1 && lifted.animation(forKey: "opacity") == nil)
        #expect(lifted.frame == CGRect(origin: .zero, size: sourceFrame.size))
        #expect(layers.filter { $0 !== lifted }.allSatisfy { $0.superlayer === grid.view.layer })
        grid.refreshImagePlans()
        #expect(lifted.frame == CGRect(origin: .zero, size: sourceFrame.size))
        #expect((lifted.contents as AnyObject?) === pixels)

        // Immediate dismissal (navigation/resize) must restore pixels in
        // this same transaction, without an opacity animation.
        grid.dismissContextMenu()
        #expect(lifted.superlayer === grid.view.layer && lifted.frame == sourceFrame)
        #expect((lifted.contents as AnyObject?) === pixels)
        #expect(lifted.opacity == 1 && lifted.animation(forKey: "opacity") == nil)
        #expect(overlay.isHidden)

        grid.presentMenu(at: 0)
        let secondOverlay = try menuWindow()
        #expect(isInside(lifted, secondOverlay.layer))
        catalog.replace(groups: [.init(id: "month", title: "September", items: Array(items.dropLast()))])
        #expect(grid.geometry?.count == 3)
        func action(_ view: UIView) -> UIControl? {
            if let control = view as? UIControl, control.accessibilityLabel == String(localized: "Show in Chat", table: "RoomProfile") { return control }
            return view.subviews.lazy.compactMap(action).first
        }
        try #require(action(secondOverlay)).sendActions(for: .touchUpInside)
        try await wait { selected != nil && grid.geometry?.count == 2 }
        #expect(selected == items[0].id)
        #expect(grid.scrollView.isScrollEnabled)
        #expect(layers.allSatisfy { $0.opacity == 1 })
        #expect(lifted.superlayer === grid.view.layer && lifted.frame == sourceFrame)
        #expect((lifted.contents as AnyObject?) === pixels)
        #expect(lifted.animation(forKey: "opacity") == nil)
        #expect(secondOverlay.isHidden)
    }
}
