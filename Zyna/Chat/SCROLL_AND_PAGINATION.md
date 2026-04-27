# Chat Scroll And Pagination

This note describes the current chat history and scroll model. The goal
is a predictable Texture datasource and stable scrolling in long
conversations.

## Core Model

For one open chat session:

- loaded history stays loaded
- older pages are appended into a session-retained dataset
- the opposite edge is not trimmed during normal browsing
- live-edge viewing and history browsing are treated as different
  viewport modes

The UI datasource is:

`Matrix -> TimelineService -> TimelineDiffBatcher -> GRDB -> MessageWindow -> ChatViewModel -> ASTableNode`

Matrix is not the direct UI datasource. `MessageWindow` owns the loaded
GRDB-backed range that the UI reads from.

## MessageWindow

`MessageWindow` manages the loaded range for one room:

- initial load uses the newest `200`
- paging uses chunks of `50`
- `windowSize` also defines the target size for `jumpTo` and
  `jumpToOldest`
- older pages remain retained as they are loaded
- `jumpToLive()` expands the loaded lower bound back to the live edge

This makes `MessageWindow` a growing session dataset, not a
trim-on-scroll mechanism.

## Update Model

Texture should mostly see:

- insert older rows
- insert newer rows
- delete rows when content is actually removed
- selective row reloads when content changes in place

The normal update path should avoid:

- large inferred `move` sets
- trimming the opposite edge during scroll
- frequent `reloadData`

Backward pagination works like this:

- load older rows from GRDB first when available
- ask the SDK for more history only after local exhaustion
- after server pagination, wait for
  `Matrix -> batcher -> GRDB -> MessageWindow` materialization before
  deciding history is exhausted

## Viewport Modes

When the viewport is pinned to live:

- incoming live messages behave like normal live inserts
- after the batch finishes, the table is pinned back to the live edge

When the user is browsing history:

- incoming live messages must not shift the viewport
- `ASTableNode` preserves offset via
  `automaticallyAdjustsContentOffset`
- insert animations for those offscreen live arrivals are suppressed
- the scroll-to-live affordance can show an unseen incoming count

Navigation uses two modes:

- near target: normal animated scroll
- far target: teleport

Far jump-to-message and far jump-to-live use teleport instead of long
autoscroll.

## Invariants

If this model is working correctly:

- an open chat session retains the history it has already loaded
- reading older history does not delete newer rows under the viewport
- incoming live messages do not push the viewport while reading history
- offscreen live arrivals can accumulate next to the scroll-to-live
  control instead of forcing auto-scroll
- ordinary history growth does not depend on large table move sets
- the UI does not declare pagination exhausted before GRDB catches up

## Do Not Reintroduce

Avoid these patterns:

- trimming the opposite edge during active history browsing
- forcing a strict sliding window on every page
- using `reloadData` as the normal pagination path
- expressing window reshaping through large inferred `move` sets
- treating manual offset compensation as the primary architecture

## Key Files

- `Zyna/Chat/ChatView.swift`
- `Zyna/Chat/ChatViewModel.swift`
- `Zyna/Services/Database/MessageWindow.swift`
- `Zyna/Services/Database/TimelineDiffBatcher.swift`
- `Zyna/Services/TimelineService.swift`
- `Zyna/Chat/Nodes/ChatNode.swift`
