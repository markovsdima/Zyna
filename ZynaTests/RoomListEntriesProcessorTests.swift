// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK
import Testing
@testable import Zyna

private final class EntriesTestRoom: Room, @unchecked Sendable {
    let roomID: String
    let calledOnMain = Atomic(false)
    init(_ id: String) { roomID = id; super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func id() -> String {
        if Thread.isMainThread { calledOnMain.wrappedValue = true }
        return roomID
    }
}

@Suite("Background room list entries")
@MainActor
struct RoomListEntriesProcessorTests {
    @Test("SDK diffs keep their order off-main and earlier snapshots remain unchanged")
    func orderedDiffs() async throws {
        let processor = RoomListEntriesProcessor()
        let a = EntriesTestRoom("a"), b = EntriesTestRoom("b")
        let c = EntriesTestRoom("c"), d = EntriesTestRoom("d")
        let replacement = EntriesTestRoom("a")
        let stream = AsyncStream<RoomListEntriesProcessor.Update>.makeStream()
        let complete: (RoomListEntriesProcessor.Update) -> Void = { update in
            #expect(!Thread.isMainThread)
            stream.continuation.yield(update)
        }
        processor.apply([.reset(values: [a, b, c])], completion: complete)
        processor.apply([.remove(index: 1), .pushFront(value: d), .set(index: 1, value: replacement)],
            completion: complete)
        processor.apply([.truncate(length: 1)]) { update in
            complete(update)
            stream.continuation.finish()
        }
        var results: [RoomListEntriesProcessor.Update] = []
        for await update in stream.stream { results.append(update) }
        try #require(results.count == 3)
        func ids(_ index: Int) -> [String] {
            results[index].snapshot.rooms.map { ($0 as! EntriesTestRoom).roomID }
        }
        #expect(ids(0) == ["a", "b", "c"])
        #expect(ids(1) == ["d", "a", "c"])
        #expect(ids(2) == ["d"])
        #expect(results[0].snapshot.roomsByID["a"] === a)
        #expect(results[1].snapshot.roomsByID["a"] === replacement)
        #expect(results[1].impactedRoomIDs == ["a", "d"])
        var hidden: Set<String> = ["a", "b", "c", "obsolete"]
        for update in results {
            for change in update.visibilityChanges { change.apply(to: &hidden) }
        }
        #expect(hidden.isEmpty)
        #expect([a, b, c, d, replacement].allSatisfy { !$0.calledOnMain.wrappedValue })
    }
}
