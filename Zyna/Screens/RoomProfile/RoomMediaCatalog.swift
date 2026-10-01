// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit
import GRDB

struct RoomMediaMonth: Equatable, Sendable {
    let id: String
    let title: String
    let count: Int
    let newest: Int64
    let oldest: Int64
}

/// Immutable event identities survive page eviction and database edits.
/// Packed UTF-8 avoids retaining a String object and payload per item.
struct RoomMediaOrder: Sendable {
    private var bytes: [UInt8] = []
    private var offsets: [Int] = [0]
    var count: Int { offsets.count - 1 }
    var storageByteCount: Int { bytes.count + offsets.count * MemoryLayout<Int>.stride }

    mutating func append(_ id: String) {
        bytes.append(contentsOf: id.utf8)
        offsets.append(bytes.count)
    }

    func id(at index: Int) -> String? {
        guard index >= 0, index < count else { return nil }
        return String(decoding: bytes[offsets[index]..<offsets[index + 1]], as: UTF8.self)
    }
}

struct RoomMediaSnapshot: Equatable, Sendable {
    let revision: Int64
    let months: [RoomMediaMonth]
    let count: Int
    let order: RoomMediaOrder
    init(revision: Int64, months: [RoomMediaMonth], order: RoomMediaOrder = RoomMediaOrder()) {
        self.revision = revision; self.months = months; self.order = order
        count = months.reduce(0) { $0 + $1.count }
    }

    // The revision owns the immutable order. Never compare the full identity
    // buffer on main, including when only relative month labels change.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.months == rhs.months
    }
}

/// Full-catalog metadata contains only months and compact event identities.
/// Payloads and SDK MediaSources are decoded only for requested pages.
final class RoomMediaDatabase: @unchecked Sendable {
    enum CatalogError: Error { case stale, invalidTimestamp }
    let database: AccountDatabase
    let roomID: String
    static let identityQuery = """
        SELECT eventId FROM roomAttachment INDEXED BY idx_roomAttachment_visual_order
        WHERE roomId = ? AND kind IN ('image', 'video')
        ORDER BY timestampMs DESC, eventId DESC
        """
    static let monthCountQuery = """
        SELECT COUNT(*) AS count, MIN(timestampMs) AS oldest
        FROM roomAttachment INDEXED BY idx_roomAttachment_visual_order
        WHERE roomId = ? AND kind IN ('image', 'video') AND timestampMs BETWEEN ? AND ?
        """
    private struct MonthCounts {
        let id: String
        let count: Int
        let newest: Int64
        let oldest: Int64
    }
    private let queue: DispatchQueue
    // Accessed only inside this account's serialized database reads.
    private var cachedOrder: (revision: Int64, value: RoomMediaOrder)?
    private var cachedMonths: (revision: Int64, timeZone: String, values: [MonthCounts])?

    init(database: AccountDatabase, roomID: String,
         queue: DispatchQueue = DispatchQueue(label: "zyna.profile.media-catalog", qos: .userInitiated)) {
        self.database = database
        self.roomID = roomID
        self.queue = queue
    }

    static func migrate(_ db: Database, merging appliedMigrations: Set<String>) throws {
        if !appliedMigrations.isEmpty {
            // Only derived catalog state is replaced. Attachment payloads and
            // discovery progress survive the unpublished development schemas.
            // This runs at database open, before any revision caches exist.
            try db.execute(sql: """
                DROP TRIGGER roomAttachmentRevisionInsert;
                DROP TRIGGER roomAttachmentRevisionUpdate;
                DROP TRIGGER roomAttachmentRevisionDelete;
                DROP INDEX idx_roomAttachment_visual_order;
                DROP TABLE roomAttachmentRevision;
                """)
        }
        // Metadata edits invalidate decoded pages without rebuilding the
        // identity buffer or recounting the image viewer's unchanged ordering.
        try db.execute(sql: """
            CREATE TABLE roomAttachmentRevision (
                roomId TEXT PRIMARY KEY NOT NULL,
                revision INTEGER NOT NULL,
                orderRevision INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX idx_roomAttachment_visual_order ON roomAttachment(roomId, timestampMs DESC, eventId DESC, kind)
                WHERE kind IN ('image', 'video');
            CREATE TRIGGER roomAttachmentRevisionInsert AFTER INSERT ON roomAttachment WHEN NEW.kind IN ('image', 'video') BEGIN
                INSERT INTO roomAttachmentRevision (roomId, revision, orderRevision) VALUES (NEW.roomId, 1, 1)
                ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1, orderRevision = orderRevision + 1;
            END;
            CREATE TRIGGER roomAttachmentRevisionUpdate AFTER UPDATE ON roomAttachment
                WHEN NEW.kind IN ('image', 'video') OR OLD.kind IN ('image', 'video') BEGIN
                INSERT INTO roomAttachmentRevision (roomId, revision, orderRevision) VALUES (NEW.roomId, 1, 1)
                ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1,
                    orderRevision = orderRevision + CASE WHEN NEW.kind != OLD.kind OR NEW.timestampMs != OLD.timestampMs
                        OR NEW.eventId != OLD.eventId THEN 1 ELSE 0 END;
            END;
            CREATE TRIGGER roomAttachmentRevisionDelete AFTER DELETE ON roomAttachment WHEN OLD.kind IN ('image', 'video') BEGIN
                INSERT INTO roomAttachmentRevision (roomId, revision, orderRevision) VALUES (OLD.roomId, 1, 1)
                ON CONFLICT(roomId) DO UPDATE SET revision = revision + 1, orderRevision = orderRevision + 1;
            END;
            """)
    }

    private func revision(in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT revision FROM roomAttachmentRevision WHERE roomId = ?",
                          arguments: [roomID]) ?? 0
    }

    private func orderRevision(in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT orderRevision FROM roomAttachmentRevision WHERE roomId = ?",
                          arguments: [roomID]) ?? 0
    }

    /// Jump between occupied months with an index seek, then count each
    /// disjoint timestamp range. Calendar work is O(months), not O(items).
    private func monthCounts(in db: Database, calendar: Calendar) throws -> [MonthCounts] {
        var months: [MonthCounts] = []
        var before: Int64?
        while true {
            var arguments: StatementArguments = [roomID]
            if let before { arguments += [before] }
            let newest = try Int64.fetchOne(db, sql: """
                SELECT timestampMs FROM roomAttachment INDEXED BY idx_roomAttachment_visual_order
                WHERE roomId = ? AND kind IN ('image', 'video') \(before == nil ? "" : "AND timestampMs < ?")
                ORDER BY timestampMs DESC, eventId DESC LIMIT 1
                """, arguments: arguments)
            guard let newest else { return months }
            let date = Date(timeIntervalSince1970: Double(newest) / 1000)
            guard let interval = calendar.dateInterval(of: .month, for: date) else { throw CatalogError.invalidTimestamp }
            let milliseconds = (interval.start.timeIntervalSince1970 * 1000).rounded()
            guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
                throw CatalogError.invalidTimestamp
            }
            let start = Int64(milliseconds)
            guard start <= newest else { throw CatalogError.invalidTimestamp }
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month,
                  let row = try Row.fetchOne(db, sql: Self.monthCountQuery, arguments: [roomID, start, newest]) else {
                throw CatalogError.invalidTimestamp
            }
            months.append(MonthCounts(id: String(format: "%04d-%02d", year, month), count: row["count"],
                                      newest: newest, oldest: row["oldest"]))
            before = start
        }
    }

    func snapshot(in db: Database, now: Date = Date(), locale: Locale = .current,
                  timeZone: TimeZone = .current) throws -> RoomMediaSnapshot {
        let revision = try revision(in: db)
        let orderRevision = try orderRevision(in: db)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if cachedMonths?.revision != orderRevision || cachedMonths?.timeZone != timeZone.identifier {
            cachedMonths = (orderRevision, timeZone.identifier, try monthCounts(in: db, calendar: calendar))
        }
        let formatter = DateFormatter()
        var localeComponents = Locale.Components(locale: locale)
        localeComponents.calendar = .gregorian
        formatter.locale = Locale(components: localeComponents)
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        let months = cachedMonths!.values.map { month -> RoomMediaMonth in
            let date = Date(timeIntervalSince1970: Double(month.newest) / 1000)
            let title = calendar.isDate(date, equalTo: now, toGranularity: .month)
                ? String(localized: "This Month") : formatter.string(from: date).capitalizingFirstCharacter(with: locale)
            return RoomMediaMonth(id: month.id, title: title, count: month.count,
                                  newest: month.newest, oldest: month.oldest)
        }
        if cachedOrder?.revision != orderRevision {
            var order = RoomMediaOrder()
            // Covering index scan: no large payload, MediaSource or image is
            // read. The old buffer stays valid while a new grid is prepared.
            let ids = try String.fetchCursor(db, sql: Self.identityQuery, arguments: [roomID])
            while let id = try ids.next() { order.append(id) }
            cachedOrder = (orderRevision, order)
        }
        return RoomMediaSnapshot(revision: revision, months: months, order: cachedOrder!.value)
    }

    func observe(onError: @escaping @Sendable (Error) -> Void,
                 onChange: @escaping @Sendable (RoomMediaSnapshot) -> Void) -> AnyDatabaseCancellable {
        // Revision callbacks are cheap. Coalesce them before entering the
        // account queue, and skip queued revisions already included in a read.
        let delivery = RoomMediaSnapshotDelivery(queue: queue,
            fetch: { [self] in try database.read { try snapshot(in: $0) } },
            onError: onError, onChange: onChange)
        let token = database.observe(ValueObservation.tracking { [self] db in try revision(in: db) }.removeDuplicates(),
            on: queue, onError: { delivery.fail($0) }, onChange: { delivery.request($0) })
        return AnyDatabaseCancellable { delivery.cancel(); token.cancel() }
    }

    func page(_ range: Range<Int>, snapshot: RoomMediaSnapshot) async throws -> [Int: AttachmentItem] {
        try await database.read { [self] db in
            guard try revision(in: db) == snapshot.revision else { throw CatalogError.stale }
            var result: [Int: AttachmentItem] = [:]
            var start = 0
            for month in snapshot.months {
                let lower = max(start, range.lowerBound)
                let upper = min(start + month.count, range.upperBound)
                defer { start += month.count }
                guard lower < upper else { continue }
                // SQLite skips index entries before reading the large payload.
                // Paging is within a month, never through the whole room.
                let records = try StoredRoomAttachment.fetchAll(db, sql: """
                    SELECT * FROM roomAttachment INDEXED BY idx_roomAttachment_visual_order
                    WHERE roomId = ? AND kind IN ('image', 'video') AND timestampMs BETWEEN ? AND ?
                    ORDER BY timestampMs DESC, eventId DESC LIMIT ? OFFSET ?
                    """, arguments: [roomID, month.oldest, month.newest, upper - lower, lower - start])
                for (offset, record) in records.enumerated() {
                    if let item = record.makeAttachmentItem() { result[lower + offset] = item }
                }
            }
            return result
        }
    }

    func index(of id: String, snapshot: RoomMediaSnapshot) async throws -> Int? {
        try await database.read { [self] db in
            guard try revision(in: db) == snapshot.revision else { throw CatalogError.stale }
            guard let timestamp = try Int64.fetchOne(db, sql: """
                SELECT timestampMs FROM roomAttachment
                WHERE roomId = ? AND eventId = ? AND kind IN ('image', 'video')
                """, arguments: [roomID, id]) else { return nil }
            var start = 0
            for month in snapshot.months {
                if timestamp >= month.oldest && timestamp <= month.newest {
                    let preceding = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM roomAttachment WHERE roomId = ? AND kind IN ('image', 'video')
                        AND timestampMs BETWEEN ? AND ? AND (timestampMs > ? OR (timestampMs = ? AND eventId > ?))
                        """, arguments: [roomID, month.oldest, month.newest, timestamp, timestamp, id]) ?? 0
                    return start + preceding
                }
                start += month.count
            }
            return nil
        }
    }

    func galleryPage(item: AttachmentItem, frame: CGRect) async throws -> ImageViewerController.Page {
        try await database.read { [self] db in try galleryPage(item: item, frame: frame, in: db) }
    }

    private func galleryPage(item: AttachmentItem, frame: CGRect, in db: Database,
                             position: (index: Int, count: Int)? = nil) throws -> ImageViewerController.Page {
        let revision = try orderRevision(in: db)
        let count = try position?.count ?? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM roomAttachment WHERE roomId = ? AND kind = 'image'", arguments: [roomID]) ?? 0
        let index = try position?.index ?? Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM roomAttachment WHERE roomId = ? AND kind = 'image'
            AND (timestampMs > ? OR (timestampMs = ? AND eventId > ?))
            """, arguments: [roomID, Int64(clamping: item.timestampMs), Int64(clamping: item.timestampMs), item.id]) ?? 0
        let preview = [512, 768, 256, 128].lazy.compactMap {
            MediaCache.shared.cachedAttachmentThumbnail(mxc: item.thumbnail?.mxc ?? item.sourceMxc, tilePixelSize: $0)
        }.first ?? item.blurhash.flatMap { BlurhashDecoder.placeholder(for: $0, aspectRatio: item.aspectRatio) }
        return ImageViewerController.Page(item: .init(previewImage: preview, mediaSource: item.source, sourceFrame: frame),
            eventId: item.id, timestampMs: item.timestampMs, index: index, count: max(1, count), catalogRevision: revision)
    }

    func adjacent(to page: ImageViewerController.Page, direction: Int) async throws -> ImageViewerController.Page? {
        try await database.read { [self] db in
            let older = direction > 0
            let comparison = older ? "<" : ">"
            let order = older ? "DESC" : "ASC"
            guard let record = try StoredRoomAttachment.fetchOne(db, sql: """
                SELECT * FROM roomAttachment WHERE roomId = ? AND kind = 'image'
                AND (timestampMs \(comparison) ? OR (timestampMs = ? AND eventId \(comparison) ?))
                ORDER BY timestampMs \(order), eventId \(order) LIMIT 1
                """, arguments: [roomID, Int64(clamping: page.timestampMs), Int64(clamping: page.timestampMs), page.eventId]),
                  let item = record.makeAttachmentItem() else { return nil }
            let unchanged = try page.catalogRevision == orderRevision(in: db)
            let position = unchanged ? (index: page.index + (older ? 1 : -1), count: page.count) : nil
            return try galleryPage(item: item, frame: .zero, in: db, position: position)
        }
    }
}

/// Queue-confined throttle, not a trailing debounce: continuous discovery
/// still publishes progress. The first snapshot is immediate; subsequent
/// reads leave at least 200 ms for chat work on the shared database queue.
private final class RoomMediaSnapshotDelivery: @unchecked Sendable {
    private let queue: DispatchQueue
    private let fetch: @Sendable () throws -> RoomMediaSnapshot
    private let onError: @Sendable (Error) -> Void
    private let onChange: @Sendable (RoomMediaSnapshot) -> Void
    private let cancelled = Atomic(false)
    private var deliveredRevision: Int64 = -1
    private var nextRead = DispatchTime.now()
    private var scheduled = false

    init(queue: DispatchQueue, fetch: @escaping @Sendable () throws -> RoomMediaSnapshot,
         onError: @escaping @Sendable (Error) -> Void, onChange: @escaping @Sendable (RoomMediaSnapshot) -> Void) {
        self.queue = queue; self.fetch = fetch; self.onError = onError; self.onChange = onChange
    }

    func request(_ revision: Int64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !cancelled.wrappedValue, revision > deliveredRevision, !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: nextRead) { [self] in
            scheduled = false
            guard !cancelled.wrappedValue else { return }
            do {
                let snapshot = try fetch()
                nextRead = .now() + .milliseconds(200)
                deliveredRevision = snapshot.revision
                if !cancelled.wrappedValue { onChange(snapshot) }
            } catch { fail(error) }
        }
    }

    func fail(_ error: Error) {
        if cancelled.tryToSetFlag() { onError(error) }
    }

    func cancel() { cancelled.wrappedValue = true }
}

/// Only a bounded set of decoded records survives a scroll. Month geometry
/// remains available even when the records and their images are evicted.
@MainActor
final class RoomMediaCatalog {
    static let pageSize = 64
    static let maximumPages = 20
    let source: RoomMediaDatabase?
    private(set) var snapshot = RoomMediaSnapshot(revision: -1, months: [])
    private(set) var error: Error?
    var onSnapshot: ((RoomMediaSnapshot) -> Void)?
    var onItemsChanged: (() -> Void)?
    private var observation: AnyDatabaseCancellable?
    private var pages: [Int: [Int: AttachmentItem]] = [:]
    private var accessOrder: [Int] = []
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var failedPages: Set<Int> = []
    private var memoryItems: [AttachmentItem] = []
    private var stopped = false
    private var calendarObservers: [NSObjectProtocol] = []
    private var calendarRefresh: Task<Void, Never>?

    init(source: RoomMediaDatabase? = nil) { self.source = source }
    deinit {
        observation?.cancel(); tasks.values.forEach { $0.cancel() }
        calendarRefresh?.cancel()
        calendarObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    var count: Int { snapshot.count }
    var cachedItemCount: Int { pages.values.reduce(0) { $0 + $1.count } }

    func start() {
        guard let source, observation == nil, !stopped else { return }
        if calendarObservers.isEmpty {
            calendarObservers = [Notification.Name.NSCalendarDayChanged,
                NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange,
                UIApplication.significantTimeChangeNotification, UIApplication.willEnterForegroundNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshCalendar() }
                }
            }
        }
        observation = source.observe(onError: { [weak self] error in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.observation?.cancel(); self.observation = nil
                self.error = error; self.onItemsChanged?()
            }
        }, onChange: { [weak self] snapshot in
            Task { @MainActor in self?.accept(snapshot) }
        })
    }

    func refreshCalendar(now: Date = Date()) {
        guard let source, !stopped else { return }
        calendarRefresh?.cancel()
        calendarRefresh = Task { [weak self] in
            do {
                let snapshot = try await source.database.read { try source.snapshot(in: $0, now: now) }
                guard !Task.isCancelled else { return }
                self?.accept(snapshot)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.error = error; self.onItemsChanged?()
            }
        }
    }

    func stop() {
        stopped = true
        calendarRefresh?.cancel(); calendarRefresh = nil
        calendarObservers.forEach { NotificationCenter.default.removeObserver($0) }; calendarObservers.removeAll()
        observation?.cancel(); observation = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        pages.removeAll(); memoryItems.removeAll(); accessOrder.removeAll(); failedPages.removeAll()
    }

    private func accept(_ snapshot: RoomMediaSnapshot) {
        guard !stopped, snapshot.revision >= self.snapshot.revision, snapshot != self.snapshot else { return }
        if snapshot.revision != self.snapshot.revision {
            tasks.values.forEach { $0.cancel() }; tasks.removeAll()
            pages.removeAll(); accessOrder.removeAll(); failedPages.removeAll()
        }
        error = nil
        self.snapshot = snapshot
        onSnapshot?(snapshot)
    }

    /// Fixture / SDK-only fallback. Production uses the database source.
    func replace(groups: [AttachmentMonthGroup]) {
        guard source == nil else { return }
        let items = groups.flatMap(\.items)
        guard snapshot.revision < 0 || items != memoryItems else { return }
        memoryItems = items
        var order = RoomMediaOrder()
        items.forEach { order.append($0.id) }
        accept(RoomMediaSnapshot(revision: snapshot.revision + 1, months: groups.map {
            RoomMediaMonth(id: $0.id, title: $0.title, count: $0.items.count,
                newest: Int64(clamping: $0.items.first?.timestampMs ?? 0),
                oldest: Int64(clamping: $0.items.last?.timestampMs ?? 0))
        }, order: order))
    }

    func item(at index: Int) -> AttachmentItem? {
        if source == nil { return memoryItems.indices.contains(index) ? memoryItems[index] : nil }
        return pages[index / Self.pageSize]?[index]
    }

    func index(of id: String, in snapshot: RoomMediaSnapshot) async throws -> Int? {
        if let source { return try await source.index(of: id, snapshot: snapshot) }
        return memoryItems.firstIndex { $0.id == id }
    }

    func prepare(_ range: Range<Int>, in snapshot: RoomMediaSnapshot) async throws {
        guard let source, !range.isEmpty else { return }
        guard !Task.isCancelled, !stopped, self.snapshot.revision == snapshot.revision else { throw CancellationError() }
        let lower = max(0, range.lowerBound / Self.pageSize)
        let upper = min(lower + Self.maximumPages, (range.upperBound + Self.pageSize - 1) / Self.pageSize)
        guard lower < upper else { return }
        if (lower..<upper).allSatisfy({ pages[$0] != nil }) {
            for key in lower..<upper {
                accessOrder.removeAll { $0 == key }; accessOrder.append(key)
            }
            return
        }
        let values = try await source.page((lower * Self.pageSize)..<min(snapshot.count, upper * Self.pageSize), snapshot: snapshot)
        guard !Task.isCancelled, !stopped, self.snapshot.revision == snapshot.revision else { throw CancellationError() }
        for key in lower..<upper {
            pages[key] = values.filter { $0.key / Self.pageSize == key }
            accessOrder.removeAll { $0 == key }; accessOrder.append(key)
        }
        trim()
    }

    func ensure(_ range: Range<Int>) {
        guard let source, !stopped, !range.isEmpty, count > 0 else { return }
        let lower = max(0, min(count - 1, range.lowerBound)) / Self.pageSize
        let upper = max(lower, min(count - 1, range.upperBound - 1) / Self.pageSize)
        let wanted = Set(lower...min(upper, lower + Self.maximumPages - 1))
        for key in Array(tasks.keys) where !wanted.contains(key) { tasks.removeValue(forKey: key)?.cancel() }
        for key in wanted.sorted() {
            accessOrder.removeAll { $0 == key }; accessOrder.append(key)
            guard pages[key] == nil, tasks[key] == nil, !failedPages.contains(key) else { continue }
            let snapshot = snapshot
            let range = (key * Self.pageSize)..<min(count, (key + 1) * Self.pageSize)
            tasks[key] = Task { [weak self] in
                do {
                    let values = try await source.page(range, snapshot: snapshot)
                    guard !Task.isCancelled, let self, !self.stopped, self.snapshot.revision == snapshot.revision else { return }
                    self.tasks[key] = nil
                    self.pages[key] = values
                    self.trim()
                    self.onItemsChanged?()
                } catch {
                    guard !Task.isCancelled, let self, !self.stopped, self.snapshot.revision == snapshot.revision else { return }
                    self.tasks[key] = nil
                    if case RoomMediaDatabase.CatalogError.stale = error { return }
                    self.failedPages.insert(key); self.error = error; self.onItemsChanged?()
                }
            }
        }
        trim()
    }

    private func trim() {
        while accessOrder.count > Self.maximumPages {
            let key = accessOrder.removeFirst()
            pages[key] = nil
            tasks.removeValue(forKey: key)?.cancel()
        }
    }

    func retry() { error = nil; failedPages.removeAll(); start(); onItemsChanged?() }
}
