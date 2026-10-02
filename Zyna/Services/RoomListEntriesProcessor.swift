// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK

/// Applies ordered SDK diffs and reads FFI IDs away from the UI thread.
/// Only immutable snapshots cross back to the service's publication path.
final class RoomListEntriesProcessor {
    enum VisibilityChange {
        case retain(Set<String>)
        case remove(String)

        func apply(to hiddenIDs: inout Set<String>) {
            switch self {
            case .retain(let ids): hiddenIDs.formIntersection(ids)
            case .remove(let id): hiddenIDs.remove(id)
            }
        }
    }

    struct Snapshot {
        var rooms: [Room] = []
        var roomsByID: [String: Room] = [:]
    }

    struct Update {
        let snapshot: Snapshot
        let impactedRoomIDs: Set<String>
        let visibilityChanges: [VisibilityChange]
    }

    private let queue = DispatchQueue(label: "com.zyna.rooms.entries", qos: .userInitiated)
    private var rooms: [Room] = []

    func apply(_ updates: [RoomListEntriesUpdate], completion: @escaping (Update) -> Void) {
        queue.async { [self] in
            var impactedRoomIds = Set<String>()
            var visibilityChanges: [VisibilityChange] = []
            for update in updates {
                applySingleUpdate(update, impactedRoomIds: &impactedRoomIds,
                    visibilityChanges: &visibilityChanges)
            }
            let byID = Dictionary(rooms.map { ($0.id(), $0) }, uniquingKeysWith: { _, last in last })
            completion(Update(snapshot: Snapshot(rooms: rooms, roomsByID: byID),
                impactedRoomIDs: impactedRoomIds, visibilityChanges: visibilityChanges))
        }
    }

    private func applySingleUpdate(
        _ update: RoomListEntriesUpdate,
        impactedRoomIds: inout Set<String>,
        visibilityChanges: inout [VisibilityChange]
    ) {
        switch update {
        case .reset(let values):
            rooms = values
            let valueIds = Set(values.map { $0.id() })
            visibilityChanges.append(.retain(valueIds))
            impactedRoomIds.formUnion(valueIds)
        case .append(let values):
            rooms.append(contentsOf: values)
            impactedRoomIds.formUnion(values.map { $0.id() })
        case .pushBack(let value):
            rooms.append(value)
            impactedRoomIds.insert(value.id())
        case .pushFront(let value):
            rooms.insert(value, at: 0)
            impactedRoomIds.insert(value.id())
        case .insert(let index, let value):
            rooms.insert(value, at: Int(index))
            impactedRoomIds.insert(value.id())
        case .set(let index, let value):
            if Int(index) < rooms.count {
                let oldRoomId = rooms[Int(index)].id()
                rooms[Int(index)] = value
                if oldRoomId != value.id() {
                    visibilityChanges.append(.remove(oldRoomId))
                }
                impactedRoomIds.insert(value.id())
            }
        case .remove(let index):
            if Int(index) < rooms.count {
                let removed = rooms.remove(at: Int(index))
                visibilityChanges.append(.remove(removed.id()))
            }
        case .popBack:
            if !rooms.isEmpty {
                let removed = rooms.removeLast()
                visibilityChanges.append(.remove(removed.id()))
            }
        case .popFront:
            if !rooms.isEmpty {
                let removed = rooms.removeFirst()
                visibilityChanges.append(.remove(removed.id()))
            }
        case .truncate(let length):
            if Int(length) < rooms.count {
                let removed = rooms.dropFirst(Int(length))
                for room in removed {
                    visibilityChanges.append(.remove(room.id()))
                }
            }
            rooms = Array(rooms.prefix(Int(length)))
        case .clear:
            rooms = []
            visibilityChanges.append(.retain([]))
        }
    }
}
