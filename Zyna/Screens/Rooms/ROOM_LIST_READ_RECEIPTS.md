# Room List Read Receipts

Zyna shows the delivery/read state of the latest own message directly in the
room list. This is not a stock Matrix room-list feature; it depends on Zyna's
Matrix Rust SDK Swift bindings.

## User Semantics

- No indicator: the latest visible message is not ours.
- Pending: the latest own message is still local/sending.
- One check: the latest own message was accepted by the server.
- Two checks: at least one other room participant has read that message.
- Failed: the latest own local message reached a terminal send failure.

Group rooms intentionally use "read by at least one other participant", not
"read by everyone".

## SDK Contract

The room-list row uses:

```swift
try await room.latestOwnMainTimelineReadReceiptSummary()
```

`EventReadReceiptSummary.hasReadReceiptFromOtherUser` is the only value needed
for the room-list indicator. If the summary is missing or the call fails, the
UI falls back to the local latest-event state.

## Refresh Trigger

The SDK fork routes sliding-sync receipt extension updates into room-info
notable updates. `matrix-sdk-ui` then emits room-list diffs, mapped in Swift as
`RoomListEntriesUpdate`.

Swift does not receive the update reason, so Zyna recomputes the status for any
room row that is added or replaced by the room-list output:

- `set`
- `insert`
- `pushFront`
- `pushBack`
- `append`
- `reset`

If the room is filtered out or outside the current dynamic room-list page, no
row update is guaranteed until it enters the output again.

## Performance Rule

Do not call the SDK summary for every room on every room-list diff.

`RoomListService` refreshes the read status only when:

- the room id is in the impacted room-list update set;
- the room is new to the current summary cache;
- the service is explicitly doing a full status refresh.

Unchanged rows keep the previous `RoomSummary.lastOwnMessageStatus`.

## Persistence

`lastOwnMessageStatus` is stored for rooms and space children so restored room
lists can show the last known indicator before the next SDK-backed refresh.
The stored value is optional; unknown future raw values decode as no indicator.
