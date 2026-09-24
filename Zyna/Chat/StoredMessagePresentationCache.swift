//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

/// Value snapshots can be copied to a page worker without sharing mutable
/// state. Decode only new/changed records, including cached nil results.
struct StoredMessagePresentationCache {
    private struct Entry {
        let record: StoredMessage
        let message: ChatMessage?
    }

    private var entries: [String: Entry] = [:]

    mutating func message(for record: StoredMessage) -> ChatMessage? {
        if let entry = entries[record.id], entry.record == record {
            return entry.message
        }
        let message = record.toChatMessage()
        entries[record.id] = Entry(record: record, message: message)
        return message
    }

    mutating func prepare(_ records: [StoredMessage]) {
        var next: [String: Entry] = [:]
        next.reserveCapacity(records.count)
        for record in records {
            if let entry = entries[record.id], entry.record == record {
                next[record.id] = Entry(record: record, message: entry.message)
            } else {
                next[record.id] = Entry(record: record, message: record.toChatMessage())
            }
        }
        entries = next
    }

    mutating func retain(_ records: [StoredMessage]) {
        let ids = Set(records.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }
}
