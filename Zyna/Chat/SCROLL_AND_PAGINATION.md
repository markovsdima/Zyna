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

`Matrix -> TimelineService -> TimelineDiffBatcher -> GRDB -> MessageWindow`

`MessageWindow -> ChatViewModel -> ChatMessageList -> Texture`

Matrix is not the direct UI datasource. `MessageWindow` owns the loaded
GRDB-backed range that the UI reads from.

`ChatMessageList` connects the full `ChatViewController` to an inverted
`ASCollectionNode` with `ChatCollectionLayout` in every configuration.
The existing cell factory, gestures, dates, glass, read receipts, and
message actions remain in the full screen. Debug and Performance also
provide a separate Custom playground; it is excluded from Release.

## Database write scheduling

The account uses one `DatabaseQueue`: moving work off-main does not make
reads concurrent with a write. Cold-start traces showed cached reads blocked
for seconds behind bulk writes. Bounded transactions let those reads finish
while discovery continues; compare whole-batch throughput as well as latency.

These bulk discovery paths use `DatabaseWriteBatch`. A transaction ends
after 64 domain updates or a 25 ms work budget, whichever comes first.
The time budget is checked between updates: a single expensive event,
commit, or observation can exceed it. This is not a hard latency guarantee.
Each producer remains serial, so queued reads and other producers can
use the connection between chunks without reordering that producer's work.

For timeline writes, one SDK event includes its message and all derived
poll, attachment, redaction, and call records. That unit never crosses a
transaction boundary. Stable event/transaction identity, monotonic read
status, cached edits, and poll tombstones are merged against current data
inside the transaction. An unchanged message is not rewritten. Existing
rows are reused within an event instead of repeatedly fetched and decoded
just to build diagnostic media-group descriptions.

Every committed history chunk advances `TimelineHistoryRevision` on the
same connection. An intervening snapshot therefore detects history even
before its notification reaches main and cannot animate it as a live
deletion. The chat receives one notification per original SDK batch, not
one per chunk. On failure, the current chunk rolls back and the committed
prefix is reported; the remaining timeline suffix still relies on later
SDK delivery/recreation for recovery, as the timeline mirror is derived
data, not the durable outgoing queue. Poll discovery retains failed input;
the attachment index retains its uncommitted suffix for the next discovery.

Demand and background history pagination share one `HistoryPaginationCoordinator`
operation: an SDK page followed by a mapper/writer barrier. The barrier flushes
pending debounce work without polling the database. It covers diffs already
delivered; later SDK listener/decryption updates still arrive through normal
refreshes. The background loop yields for 150 ms between completed pages.
Only the SDK's `reachedStart` result establishes server exhaustion. An unchanged
row count, service-only page, skipped request, or empty local read cannot do so.
Errors end the current attempt without marking history complete. Cancelling a
waiter preserves the shared request; chat cleanup cancels it and rejects late
results. Background sync starts after the SDK listener is ready.

Atomic snapshot replacements (rooms/spaces), outgoing intents, migrations,
and manual repair are not split by this helper. Initial and jump snapshots
are prepared off-main. Search, navigation existence checks and some action
paths still contain synchronous DB access; bounded discovery
writes reduce their contention but do not make those APIs asynchronous.
Converting the whole app to `DatabasePool` would require storing history
revisions in the same database snapshot, plus auditing observation and
account lifecycle semantics; replacing the connection type alone is unsafe.

### Journal mode

The application does not currently request WAL. `DatabaseQueue` leaves the
journal mode unchanged by default; diagnostics read the actual pragmas instead
of assuming a file's mode from configuration alone. More, smaller commits can
increase total I/O, so compare whole-batch time as well as cache-read latency.
WAL on the same queue would not add parallel reads or remove the need to bound
transactions. It also introduces checkpoints, which can lengthen some commits.

The pinned GRDB implementation of `Configuration.journalMode = .wal` also sets
`synchronous = NORMAL`, after its `prepareDatabase` callbacks. Any WAL experiment
must explicitly preserve FULL after opening the queue: this database contains
durable outgoing intents as well as rebuildable history. Do not benchmark a
durability downgrade as though it were only a journal-mode change.
`LocalDataProtection.protectExistingDatabaseFiles` and database removal already
include the database, `-wal`, `-shm`, and `-journal` files.

See [SQLite WAL](https://www.sqlite.org/wal.html) and
[synchronous modes](https://www.sqlite.org/pragma.html#pragma_synchronous).

### Startup outbox scans

Bulk candidate and missing-asset reads for text, image, video, voice, files,
forwarded media, edits, reactions, and redactions now await GRDB's asynchronous
reader. Poll scans already used asynchronous storage. Snapshot construction
stays inside that reader; retry bookkeeping and send orchestration stay on
main. Callers discard results after cancellation or a session change. A
missing-asset failure rechecks asset existence, queued state, and attempt
identity inside the failure transaction, so an asset prepared after the scan
cannot be marked missing from stale data.

Single-action writes and some chat reads remain synchronous.

### Database startup and migrations

`LocalDataBootstrap` now starts a shared background task from AppDelegate.
Fresh-install cleanup and stored-account resolution run before database opening.
AppCoordinator awaits that task before constructing screen models or starting
outboxes; until then it displays the launch storyboard. Session restoration,
including an incoming-call launch without a scene, awaits the same task.

DatabaseService serializes opening, migrations, account-cache preparation, and
logout cleanup on a dedicated lifecycle queue. Only a fully migrated connection
is published. `dbQueue` returns an `AccountDatabase` for that activation, not a
raw GRDB queue; callers must still await startup before the first access.

AccountDatabase admits each read/write under a short lock, then runs GRDB with
no lifecycle lock held. Retirement rejects new accesses with `AccessError.retired`,
cancels observations, and drains admitted operations before closing the raw
queue. Each history chunk has its own admission: a running transaction finishes,
but the unstarted suffix is discarded when the account retires. This prevents
GRDB/SQLCipher's crash when a retained queue calls `read()` after `close()`.
The lifecycle worker waits for draining; main and `dbQueue` getters do not.
During replacement (including a failed open), the getter returns the retired
handle until the new account is ready. A captured handle never switches accounts,
even when the next login uses the same database path.

MessageWindow rejects prepared pages after retirement, and TimelineDiffBatcher
checks the handle again when delivering its flush on main. Observations are
registered through the account owner, cancelled before close, and gated before
delivery. No raw queue is exposed to application consumers. Code that starts
new account-bound work must still capture the correct account handle/session
before scheduling it; this mechanism cannot infer the owner of an old payload
that explicitly requests the new active account later.

Closing, deleting account data, and opening the anonymous store are one queued
operation. Activation completes before login publishes its authenticated state;
cancelling a waiter does not interrupt a migration. AccountDatabaseTests hold
real reads, writes, and timeline chunks across retirement, resume non-cancelled
old requests after replacement, and check stale UI pages and queued observers.

`eraseDatabaseOnSchemaChange` is disabled. The ordinary migration-version check
still runs, but startup no longer builds a temporary encrypted database, replays
all migrations for comparison, or erases cached history and durable outgoing
intents on schema drift. Future changes to an already shipped schema require a
new versioned migration. Existing recovery for `SQLITE_NOTADB` is unchanged.
Lifecycle tests use real SQLCipher files to check a fresh schema, upgrade from
v28, reopen, and preservation of cached messages and queued media/polls.

For a device teardown trace, keep the `[PollCache]` output from launch through
sign-out and the next sign-in. The Debug-only **Settings → Diagnostics →
Database handoff test** makes the retained-reference case deterministic:

1. Choose **Arm**, then open any chat → Attachments → Polls. The first catalog
   page is suspended before its GRDB read; cached observation can still show
   rows. Wait for `handoff-held` in the console, or revisit the settings entry
   to see **Read held — sign out**. No large history or fast navigation is needed.
2. Sign out normally, then sign in without terminating the app process. The
   anonymous database opened during logout does not release the operation.
   Use the same account for a new session, or another account for a switch.
3. After the authenticated database is ready, `handoff-result` reports
   `oldClosed`, `newDistinct`, `sameAccount`, and `taskCancelled`. The expected
   retained-reference reproduction is `oldClosed=true newDistinct=true`.
   `sameAccount=true` is valid for a repeat login; `taskCancelled=true` normally
   follows closing the old screen. The settings entry also offers **Copy Report**.

The gate holds one operation using a continuation, without an open SQL
transaction. It survives UI cancellation to simulate a delayed callback;
**Cancel Test** releases it. Closing the account before capture reports
`handoff-not-captured`. The probe is opt-in and absent from Release.

It checks physical closure and aborts before SQL (`sqlAttempted=false`).
**Captured** confirms a retained reference, not production rejection or account
isolation. `AccountDatabaseTests` exercise rejection without this interception;
`DatabaseHandoffProbeTests` cover the catalog hook, lifecycle and cancellation.
Check actual chat and attachment content after switching accounts as well.

Compare `logout-*`, `database-close-*`, `database-cleanup-*` and writer markers
by `db`; opening the anonymous store changes that tag. Batcher deinit does not
mean queued closures released their database. If a crash occurs, retain the
backtrace; a crash-free run alone cannot prove all stale accesses are safe.

## MessageWindow

`MessageWindow` manages the loaded range for one room:

- initial load uses the newest `200`
- paging uses chunks of `50`
- `windowSize` also defines the target size for `jumpTo` and
  `jumpToOldest`
- older pages remain retained as they are loaded
- `jumpToLive()` from a history window loads the newest `200`; from a
  window already at the live edge, it preserves the retained history

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

Redaction preparation collects deleted records once and only builds the previous
identity index when that subset is nonempty. Previous display aliases are needed
only for candidate remote animations. Empty hidden/pending collections and empty
partial-reflow previews skip their identity scans and preview pass; active state
still goes through reconciliation and pruning. Diagnostic scans are gated before
preparation, and `ScopedLog` evaluates message expressions only when enabled.

Backward pagination works like this:

- load older rows from GRDB first when available
- ask the SDK for more history only after local exhaustion
- after server pagination, drain received diffs and try the local page once
- empty/filtered pages continue server pagination while the older edge is
  wanted; only stale local snapshots retry locally (at most three attempts)
- SDK `reachedStart` establishes server exhaustion independently of late
  decryption materialization; new local rows remain eligible after that result

## Viewport Modes

When the viewport is pinned to live:

- incoming live messages behave like normal live inserts
- after the batch finishes, the list is pinned back to the live edge

When the user is browsing history:

- incoming live messages must not shift the viewport
- Collection samples the old geometry and current offset at Texture's
  UIKit commit, then preserves a surviving row ID through
  `targetContentOffset(forProposedContentOffset:)`
- insert animations for those offscreen live arrivals are suppressed
- the scroll-to-live affordance can show an unseen incoming count

The layout reads measured heights and row IDs from Texture's committed
element map, not from a newer pending datasource. Late height changes use
an invalidation context's `contentOffsetAdjustment`. Ordinary scrolling
queries a cached geometry range; it does not rebuild or measure the list
on each tick.

Navigation uses two modes:

- near target: normal animated scroll
- far target: teleport

Far jump-to-message and far jump-to-live use teleport instead of long
autoscroll.

## Do Not Reintroduce

The model above depends on these constraints:

- do not trim the opposite edge or force a sliding window while browsing;
- do not use `reloadData` or large inferred `move` sets for ordinary paging;
- preserve the viewport through layout anchoring, not ad hoc offset corrections;
- track SDK exhaustion separately from the availability of cached local rows.

## Debugging Decryption Placeholders

In Debug builds, long-press a bubble and select **Message diagnostics**.
The report can be copied from the alert and is also logged with the
`[MessageDiag]` prefix. It compares the selected row in the window's
account database with the current SDK timeline and `Room.inspectTimelineEvent`.
Collection runs off the main actor and never switches to a
replacement account's database or SDK objects.

Decryption failures use `contentType = unableToDecrypt` and a stable reason.
Legacy rows may contain a localized error label. Neither that label nor absence
from the SDK window proves a row should be deleted; see the repair rules below.

The report includes a bounded, in-memory trail of recent diffs from the
current batcher. This Debug-only ring performs no SQL, JSON parsing, or
console logging during normal timeline processing. Full JSON, message
bodies, ciphertext, keys, and arbitrary SDK error descriptions are excluded
from reports. The selected event ID is retained for comparison with Element;
account, room, sender, and encryption session identifiers are hashed.

The SDK inspection may use its cache instead of contacting the server. It
retries encrypted envelopes with current keys, returns a typed disposition,
and does not write its result into the SDK event cache. The report itself
does not modify Zyna's message storage. See [Event Inspection FFI](MATRIX_SDK_EVENT_INSPECTION_FFI.md).

## Retained Decryption Repair

Migration `v30_messageDecryptionRepair` seeds a durable queue from typed
failures and the two old localized labels using frozen SQL. A label match
only selects a candidate; it does not rewrite or delete a message. New SDK
projections enqueue typed failures only, so ordinary text matching an error
label remains ordinary text.

`MessageDecryptionRepair` starts after the normal chat timeline attaches.
It captures the room and `AccountDatabase`, inspects serially off-main,
reads at most eight due candidates per page, and yields between requests.
An indexed due queue prioritizes the current or newly paged raw timestamp
span, then favors recent history on its initial pass. Failures
back off from 15 seconds to five minutes. A 15-second tick retries due work;
SDK flushes wake it sooner, and removal/replacement of a known UTD resets
that candidate's delay. No task, SQL query, or JSON parsing is added to cells
or ordinary scrolling. No per-event focused SDK timeline is created.

SDK `hidden` and explicit `ChatEventVisibility` exclusions remove a candidate.
For `visible` inspections, Zyna call carriers, unredacted legacy call invites
and empty text follow the ordinary mapper's exclusions. One validated custom
type, `io.element.call.reaction`, can also be excluded when the SDK returns
`indeterminate`: it must have no decryption failure, an unredacted non-state
envelope, a nonempty emoji, and an `m.reference` event target. Other unknown or
malformed events and MatrixRTC notifications remain unresolved or displayed
according to their normal policy. The proof records its reason in `lastOutcome`.
The candidate's generation and complete stored row must still match the
inspected snapshot inside the write transaction.
Confirmed hidden identities remain in the account database and suppress
late UTD replays, including after reopening the database. A subsequent
real SDK projection can supersede that proof. Positional removal alone
never deletes cached history. Real errors, unknown events, and missing keys
remain; confirmed UTDs upgrade legacy labels to typed failures.

Other `visible` results do not provide an aggregated projection: the
ordinary SDK timeline must supply resolved messages, edits, and poll results. An
out-of-window visible candidate remains cached until normal history
materialization catches up. A literal error-label message proven visible
is removed from the repair queue while its text remains intact.

Repair writes share the batcher's serial write queue and commit revision.
Notifications use `includesUnreportedHistory`, so cache cleanup cannot
animate as a live remote redaction, even when combined with an SDK flush.
The refresh queue records that provenance immediately and coalesces repair-only
reads using a fixed 500 ms deadline. Live/local updates consume pending repairs
without waiting. Each write and history revision still commits immediately;
the throttle delays snapshot preparation, not storage or hidden-event proofs.

Repair reports whether a committed mutation affects admitted rows. Removing
an excluded placeholder or updating its failure reason sets
`onlyUnadmittedChanges`; admitting a literal error-label message does not.
For an initialized window, a pure cleanup batch reads only raw older/newer
availability (at most one ID per side). It keeps the message array, cluster
neighbors and raw cursors, and never prepares a render or claims to have
read a newer full history snapshot. Boundary changes invalidate stale page
requests. The recovery notice continues observing its own bounded queue.
An ordinary SDK/local/catalog notification clears the narrow flag when
merged. If it arrives during the boundary read, the result is discarded and
the shared refresh queue prepares a full snapshot with all provenance.
Uninitialized windows also use the full path.

Chat cleanup cancels the inspector and queued writes; account retirement
rejects old accesses and late results without following the new account.
Already admitted writes can finish on their original database. Debug logs
under `[MessageRepair]` contain batch counts only; long-press diagnostics
provide event-specific classification without exporting decrypted content.

### Admission before presentation

Migration `v31_decryptionPresentation` adds the last inspection outcome and
indexes for focused work and presentable boundary neighbors. It upgrades an
already applied v30 without resetting pending generations or hidden proofs.
Early v30 development schemas without `priorityTimestamp` receive a frozen
SQL backfill from matching stored messages before the indexes are created.

`MessageWindow` reads raw rows for cursors and separately admits displayable
rows in the same database snapshot. An incoming missing-key snapshot cannot
downgrade an already resolved cached projection; explicit SDK trust restrictions
still apply. Typed UTDs are excluded immediately;
legacy labels are excluded only while their matching repair record remains
pending. A proven literal label, or a normal SDK text projection containing
that label, is ordinary text again. No timer admits unresolved events.

Initial loads, both page directions, refreshes and jumps use this gate before
building chat models or Texture nodes. `historyPageQueue` prepares message
models, outgoing envelopes, reaction/removal overlays, clusters, media groups,
date dividers, navigation indices and the table diff. Messages and durable
local state are read in one transaction. Preparing does not consume a pending
redaction confirmation or retire an outgoing envelope.

Main captures value snapshots of its UI state and accepts a result only when
the account, window revision and presentation revision still match. Local
hide/restore, animation previews and outgoing notifications invalidate older
preparations. History provenance arriving during preparation is merged before
acceptance; a changed animation policy requires preparing again. The window
and its prepared rows are committed together. Pagination completion and the
teleport swap therefore still see the final row indices synchronously.

Presentation-only hide/restore requests coalesce on the same worker. Their
revisions prevent an older page from resurrecting a locally hidden bubble.
A presentation-only rebuild cannot consume a DB confirmation that has not
yet been processed by a window update; it retains the local animation intent.
Envelope retirement and redaction acknowledgement run after UI acceptance on
the captured account's database, comparing records again before deletion.
Retired accounts reject the work; asset paths use the captured account ID.

Raw page counts and cursors advance even when no messages are admitted;
pages of only unresolved events cannot block history pagination. Cluster
peeks skip excluded rows while raw neighbors determine paging eligibility.

`ChatHistoryRecovery` observes at most 201 pending outcomes off-main. After
1.5 seconds of unresolved history it shows a single control outside the
message list. Its details distinguish missing keys and lookup failures;
"Check again" resets at most 32 candidates in the latest focus span. Fast
resolution cancels the notice, and cleanup/retirement prevents late reveal.
Unresolved rows remain stored through failures, offline use and restarts.

SDK projection changes that admit or withhold a previously stored message
carry history provenance, including in snapshots ahead of their callback.
The existing refresh queue batches them; the list preserves its viewport
without insertion/deletion animations or increasing its incoming badge.

### SDK projection recovery

The repair worker also recovers SDK projections in Release builds. It walks
the durable unresolved queue in keyset pages of 16 (at most one page per 5 s),
independently of inspection's network backoff. Only rows already confirmed
`projection` are looked up in the current SDK timeline. A matching Megolm UTD
can request `retryDecryption`; absent items, completed items and other outcomes
cannot. These lookups fetch no events or focused timelines. The linked SDK
limits explicit retries to the supplied sessions. Requests remain coalesced
and back off from 15 s to 5 minutes while projections are pending. Manual
retry resets that backoff but keeps a 15 s minimum.
Only normal SDK diffs update messages and resolve the queue. Lookup or request
success alone never removes a row or dismisses the notice. The worker checks
cancellation/account retirement before dispatch and uses its captured timeline.

## Key Files

- `Zyna/Chat/ChatView.swift`
- `Zyna/Chat/ChatViewModel.swift`
- `Zyna/Chat/ChatMessageList.swift`
- `Zyna/Chat/ChatCollectionLayout.swift`
- `Zyna/Chat/ChatListGeometry.swift`
- `Zyna/Services/Database/MessageWindow.swift`
- `Zyna/Services/Database/TimelineDiffBatcher.swift`
- `Zyna/Services/TimelineService.swift`
- `Zyna/Chat/Nodes/ChatNode.swift`
