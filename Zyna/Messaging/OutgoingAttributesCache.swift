//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Short-lived in-memory cache of Zyna attributes we just sent.
///
/// Problem it solves: the typed `timeline.send` path produces local-echo
/// events and first sync confirmations without the raw original JSON
/// prepared by the SDK's lazy provider. During that window
/// `TimelineService.extractZynaAttributes` returns empty attributes,
/// which makes a coloured bubble momentarily render as the default
/// blue before the proper raw JSON arrives and the cell is redrawn.
///
/// This cache stores attributes keyed by (roomId, body, senderId) for
/// a short TTL right after we issue a send. When the typed event
/// surfaces as our own (`isOwn == true`) without raw JSON, we look it
/// up here and return the cached attributes as an optimistic fallback.
///
/// Entries expire by TTL; the cache also self-cleans opportunistically.
final class OutgoingAttributesCache {

    static let shared = OutgoingAttributesCache()

    /// How long a pending send keeps its optimistic attributes alive.
    /// Long enough to cover sync delays, short enough to avoid cross-
    /// contamination with an unrelated later message of the same body.
    private static let ttl: TimeInterval = 8

    private struct Entry {
        let attributes: ZynaMessageAttributes
        let expiresAt: Date
    }

    private struct Key: Hashable {
        let body: String
        let senderId: String
    }

    private let queue = DispatchQueue(label: "com.zyna.outgoingAttributesCache")
    private var entries: [Key: Entry] = [:]

    // MARK: - API

    /// Stores attributes for a message just handed to `timeline.send`.
    func remember(
        attributes: ZynaMessageAttributes,
        body: String,
        senderId: String
    ) {
        let key = Key(body: body, senderId: senderId)
        queue.sync {
            entries[key] = Entry(
                attributes: attributes,
                expiresAt: Date().addingTimeInterval(Self.ttl)
            )
            pruneExpiredLocked()
        }
    }

    /// Returns previously-remembered attributes for an own event whose
    /// raw JSON has not arrived yet. Does not remove the entry —
    /// multiple timeline diffs may hit the same row.
    func peek(body: String, senderId: String) -> ZynaMessageAttributes? {
        let key = Key(body: body, senderId: senderId)
        return queue.sync {
            guard let entry = entries[key], entry.expiresAt > Date() else { return nil }
            return entry.attributes
        }
    }

    // MARK: - Private

    private func pruneExpiredLocked() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
    }
}
