# Room Attachments (Shared Media)

Room Details → Attachments lists media, voice messages, files and polls.
The SwiftUI screen uses account-bound GRDB catalogs with SDK history discovery.
Data sources and lifecycle are separate from the view for a future Texture UI.

## Polls tab

The SwiftUI screen now includes Polls. Each visited tab keeps its view and scroll
position while another tab is selected. Footer visibility belongs to each tab;
only the active tab can request pagination, and an interrupted attachment fill
resumes its remaining target on return. The polls list shows question, author,
date, lifecycle state, and the voter count only when results are disclosed.
Tapping a row returns to the matching room's chat and focuses its event.
If the poll exists only in the catalog, navigation joins ordinary chat history
pagination and its writer barrier until the full message is available. It never
inserts an isolated catalog row or inspection result into chat history. Cached
full messages need no SDK pagination. SQL and presentation preparation run off
main before the attachments screen is dismissed.

The list shows loading, Cancel, and a retryable failure. Leaving Polls, closing
attachments, or changing accounts prevents late navigation. Preparation is
committed synchronously only while the requesting screen is still current.
History search has a 30-second budget between pages (a running shared SDK call
may exceed it); reaching the server start allows up to 3 seconds for trailing
listener/decryption updates. A missing, deleted, hidden, or undecodable target
leaves attachments open. Cancel stops the navigation waiter, not a shared page
that background history sync may still need.

`RoomPollsViewModel`, `RoomPollCatalog`, and `SDKRoomPollHistorySource` live outside
the SwiftUI screen so a future Texture pager can reuse their state and lifecycle.
The source starts only on first opening Polls; switching away stops further fill
batches, while its listener and bounded catalog observation remain alive. Popping
the attachments screen explicitly cancels observation and the SDK listener.

The account-bound catalog observes `roomPoll` and pending operations, initially
30 rows plus a lookahead. Load More expands that window. Reads, JSON decoding,
SDK diff mapping, and database writes run off-main. Discovery does not insert
partial rows into `storedMessage`; existing poll bubbles receive updated content
and explicit redactions without replacing their storage identity. Committed
changes to chat rows or outgoing actions notify the chat once per committed chunk; its
snapshot and presentation are prepared on the existing background refresh queue.
Notifications carry their origin: catalog changes preserve history provenance,
while local poll actions do not suppress concurrent live deletion animations.
Both refresh outgoing presentation even when stored history is unchanged.
Unavailable sender profiles preserve cached names, while loaded profiles can
rename or clear them. Failed writes remain queued, and their error stays visible
until the source acknowledges a successful flush, including an explicit retry.

The filtered SDK timeline includes unstable/stable poll starts and undecrypted
`m.room.encrypted` events. Rust still aggregates edits, responses, and ends; the
integration test exercises this filter through the linked XCFramework. A missing
key remains visible in the pending banner and can be retried. Timeline trims and
resets never delete catalog entries. Explicit redactions use the existing poll
tombstones and outgoing-action reconciliation.

History discovery uses 100-event batches with a 2.5-second fill budget and a
100-batch safety cap. A running SDK call can exceed the budget. Sparse history
then requires Load More; incoming snapshots do not restart it. The room start
requires a confirming call with no additional rows, followed by a bounded quiet
window for listener delivery. This does not claim that all missing keys arrived.

Catalog writes share the bounded transaction policy described in
`SCROLL_AND_PAGINATION.md`. Poll discovery and media-index writes yield the
account's database connection between whole-event updates, allowing cached
reads while a large timeline flush is still running.

For Media, Voice, and Files, the initial-page check uses indexed counts once
available and timeline counts otherwise. A full page already in the timeline
does not trigger extra initial pagination while the index is still loading.

### Poll cache diagnostics

Enable the `.polls` log scope in a Debug build when investigating the catalog.
It is disabled by default during compact history timing measurements. Filter
Xcode's console or Console.app for `[PollCache]` and retain output from both
sides of an app restart.
`run` identifies the process; `db`, `room`, and event tags are stable hashes.
Poll text, answers, and raw identifiers are excluded. The trace covers database
row counts before/after migration, committed/rolled-back writes, decoded reads,
model publication, row appearance, and SDK startup/pagination. A `pollRows=-1`
means the catalog table did not exist yet. `undecodable` counts stored entries
excluded because their snapshots could not be decoded. At most 12 event tags
are printed per read, alongside total counts and the requested window limit.

`tMs` is monotonic time since the first trace entry. `waitMs`, `workMs`, and
`deliveryMs` separate connection wait, fetching/decoding, and delivery.
`writer-begin`/`writer-end` identify bulk producers and chunk sizes. `workMs`
measures the write closure; `transactionMs` also includes commit and synchronous
observers. `writer-batch-end` reports total elapsed time, committed entries,
chunk count, and success/failure for one original batch. The `batch` tag groups
interleaved producers. `db-settings` records the actual journal mode,
synchronous level (2 = FULL), and WAL auto-checkpoint threshold after migration.
`database-open-begin`/`database-open-end`, `database-migrate-end`, and
`database-ready` separate opening, migration, and total preparation time.
They run on the database lifecycle worker (`main=false`); the UI awaits the
shared bootstrap before constructing screens that read storage.

Slow transactions include `access=read` for query-only reads and bounded
statement fingerprints. A COMMIT does not imply a write; `write-capable` only
means writes were allowed. `traceDatabase(includeCallStacks: true)` adds caller
symbols but is off by default: symbolication can itself hold the connection.
Asynchronous callers may show only worker frames. SQL text and arguments are
never logged. Database tags exclude the installation's iOS container prefix.

The trace is diagnostic only: it does not change caching or pagination. Its
database checks run on the database queue; per-row write tracing only records
changed polls after transaction completion. Disable `.polls` in `LogConfig`
after collecting the reproduction.

## What the screen does

```text
Chat timeline ── TimelineDiffBatcher ───────────────┐
Filtered SDK timeline ── AttachmentTimelineStore ──┤
                                                  ▼
                                     GRDB roomAttachment
                                                  │ observation / off-main grouping
                                                  ▼
                           RoomAttachmentsViewModel → SwiftUI
                                                  │ per-tile thumbnail plan
                                                  ▼
                      MediaCache (memory → disk → SDK; demand tickets and lanes)
```

Files: `Zyna/SwiftUIScreens/RoomAttachments/*`, `Zyna/Services/Media/AttachmentThumbnailPlan.swift`,
`Zyna/Services/Media/BlurhashDecoder.swift`, `Zyna/Services/Media/AttachmentFetchMeter.swift`,
`Zyna/Services/MediaCache.swift` (Attachments section), `Zyna/UIComponents/QuickLookPresenter.swift`,
`Zyna/Models/RoomAttachmentKind.swift`, `Zyna/Services/Database/StoredRoomAttachment.swift`, and
`ChatsCoordinator.showRoomAttachments`.

Media discovery uses `AttachmentSource` / `SDKTimelineAttachmentSource`;
[the persistent index](#persistent-attachment-index) is the screen's catalog.
Poll discovery has its own source described above.

## SDK constraints

1. **Thumbnails of encrypted media are the full file.** `crates/matrix-sdk/src/media.rs:450-481`:
   for `MediaSource::Encrypted` the `Thumbnail(w,h)` format is ignored; the whole file is
   downloaded and decrypted in memory. Upstream caches it under the *request* key
   (`<mxc>_scale_WxH`, `crates/matrix-sdk-base/src/media/mod.rs:104-152`), so `getMediaThumbnail`
   followed by `getMediaContent` on one encrypted source was two downloads and two cache rows — the
   fork normalises encrypted thumbnail requests to the `File` key (see "Done in the fork"). No
   in-flight de-duplication in the SDK, no download timeout (`Duration::MAX`).
2. **Media store**: separate `matrix-sdk-media.sqlite3`, encrypted at rest because Zyna sets a
   passphrase (`MatrixClientService.swift:528`). Default policy: 400 MiB, **files > 20 MiB are
   silently not cached**, 60-day expiry. `Client.setMediaRetentionPolicy` exists; unused.
3. **Filtered timeline**: `timelineWithConfiguration(focus: .live, filter: .onlyMessage(types:) | .all, …)`.
   Element X builds its "Media and files" on two of these.
4. **Upstream `.onlyMessage` loses undecrypted events for good** (fixed in the fork).
   `bindings/matrix-sdk-ffi/src/room/mod.rs:450-465` returns `false` for `m.room.encrypted`, so a UTD
   gets no timeline item. When the key arrives the event cache redecryptor
   (`crates/matrix-sdk/src/event_cache/redecryptor.rs:386-425`) emits `VectorDiff::Set`, which the
   timeline drops (`matrix-sdk-ui/src/timeline/controller/state_transaction.rs:179-202`, "Set update
   dropped because there wasn't any attached timeline item index"). With a UTD item present the
   `Set` replaces it in place; if it decrypts into something invisible the item is removed (`:940-952`).
5. **Pagination**: the initial `.reset` carries only the last ~20 items (skip count,
   `matrix-sdk-ui/src/timeline/subscriber.rs:144-156`). `paginateBackwards(n)` first reveals
   already-loaded hidden items (no I/O), then the event cache loads **one chunk per call** from disk
   (`event_cache/caches/room/pagination.rs:161-273`, ~10–20 ms), then `/messages` — unfiltered,
   because a server-side msgtype filter is impossible for E2EE. Gaps between sync sessions are
   resolved through `/messages` even when the events on both sides are on disk (0.3–1.4 s each).
   A filtered timeline emits **no diff at all** for a chunk without attachments. Pagination is
   shared per room: a second caller awaits the in-flight future
   (`event_cache/caches/pagination.rs:112-197`), so our loop and the chat's `syncFullHistory` never
   double-hit the server. The pagination status is shared too — treat it as a spinner.
6. **The timeline's item pipeline lags behind the event cache.** `paginateBackwards` returns as
   soon as the chunk is in the event cache; turning events into items runs in the timeline's own
   task (`handle_remote_events_with_diffs`, `tasks.rs`), and the FFI forwards diffs to Swift in yet
   another task. Under a tight loop the items of the last chunk reached the listener seconds after
   `hitStart` (probe: `getEventTimelineItemByEventId` already found them). Neither the return value
   nor the pagination status reflects that backlog. `paginate_backwards` also returns `true` straight
   from the event cache without consulting the subscriber skip count, while the status subscription
   is mapped through `map_pagination_status` (`controller/mod.rs`) — two channels of one fact that can
   disagree. The event-cache broadcast to timelines holds 32 updates (`caches/room/updates.rs`); an
   overflow resets the timeline (`Lagged behind event cache updates`) — **never observed** here.
7. **Keys**: backup download on UTD is automatic
   (`backupDownloadStrategy(.afterDecryptionFailure)`). Relogin recovery can
   arrive in waves. Keys written by the NSE may need an explicit retry in the
   main process; a completed pagination call does not prove decryption finished.
   Current chat recovery is described in
   [SDK projection recovery](SCROLL_AND_PAGINATION.md#sdk-projection-recovery).
8. **FFI model**: `ImageInfo/VideoInfo` carry `thumbnailSource`, `thumbnailInfo`, `blurhash`,
   dimensions, `duration`; `AudioMessageContent.voice != nil` marks voice notes. `MediaSource`
   exposes only `url()` (same for plain and encrypted) and `toJson()` (`"file"` key ⇒ encrypted).
   `Room.loadOrFetchEvent(eventId:)` (fork) reads the event cache first, then `/event`.

## Rules adopted

- **Never call `getMediaThumbnail` for an encrypted source.** `AttachmentThumbnailPlan` is the one
  place that decides: blurhash → sender thumbnail (encrypted → `getMediaContent`, plain →
  `getMediaThumbnail`) → full original via `getMediaContent` only if `info.size` ≤ 2 MiB (default,
  DEBUG-adjustable) or on tap. `info.size` is sender-declared and the SDK has no size-capped
  download, so the threshold is a policy, not a traffic guarantee; 4–7 MB originals measured
  11–65 s on a slow link, hence the low default. Video without a thumbnail shows blurhash only —
  video bytes are never fetched for a preview and server-side video thumbnails are not requested
  (Synapse does not produce them; verify against our homeserver before relaxing for plain video).
- Tiles are downsampled with ImageIO to a square `tilePx` (bucketed ×32) and cached in
  `MediaCache` under `<mxc>|att-v1|sq<px>` (memory tier 48 MiB cost limit, disk via the existing
  record format). Bytes are de-duplicated by `(mxc, sdk key)`; the viewer goes through the same
  path (`MediaCache.loadFullContent`), so a tile still downloading an original and the viewer
  opening on top of it share one SDK call.
- **Lanes**: separate gates for thumbnail files (3), originals (1) and viewer loads (2). One shared
  gate let two 4–7 MB originals queue 22 thumbnails for 6.5 s on average; an unbounded viewer lane
  let a fast swipe leave ten originals downloading (an SDK call cannot be cancelled once started);
  the viewer also debounces page changes by 250 ms and never re-fetches an original it already has.
  Mitigation, not a guarantee: two loads already started can still hold both viewer permits while a
  third page waits, because an SDK call cannot be cancelled once started.
- **Demand tickets**: consumers hold a ticket while they wait; a tile that scrolls away withdraws
  it, and a producer that reaches its gate with no demand left skips the download (stale producers
  still pass the FIFO, as microsecond hops rather than bytes). Single-flight entries carry a token:
  any waiter removes the finished task with `removeIfCurrent`, which never evicts a newer task under
  the same key and lets a `noDemand` retry start a fresh producer.
- **Cache generation**: requests capture a `CacheContext` (generation + directory) on entry; in-flight
  and demand keys carry the generation, memory publishes are checked under the same lock that
  `activate`/`clearAll` bump and clear under, and disk writes re-check on the I/O queue — a download
  that outlives a logout cannot join, publish or write into the next account's caches.
- **Fill loop**: batches of 100 events under a 2.5 s time budget per fill (a 200-batch cap is only a
  safety net), a 10 ms per-batch wait in `.onlyMessage` (1 s in `.all`), then "Load More". A batch
  in flight always completes. `hitStart` is committed only after a confirming call that reveals
  nothing (guards the lazy-reveal case), and a fill ends only after snapshots have been quiet for
  500 ms (`settling`, capped at 6 s) because of fact 6. `.exhausted` therefore means "the raw
  history frontier is reached"; that every readable attachment has been materialised into the
  store is only as certain as the quiet window — a heuristic, not a barrier (the GRDB cross-check
  after an unclean settle is indicative for the same reason). Only explicit intents (tab switch, sentinel,
  Load More) may wait for a running fill and are replayed once; snapshot-driven re-arms never queue,
  otherwise a forced replay would bypass the budget and pump the whole room. Stats: `waitTimeouts`,
  `lateSnapshots`, `settleCap` show how often the heuristics bite.
- **UTDs** are counted in a banner ("N messages are waiting for keys"), not rendered as tiles: the
  msgtype of an undecrypted event is unknown. Retry on tap, on foreground, and on a stall (no
  decryption within 5 s — the pending count is the wrong signal, it grows while the chat paginates).
- Diffs are applied in order on a serial queue; rows stay 1:1 with SDK items. Snapshots publish on
  the leading edge (a pagination batch is one diff) and debounce only bursts.
- Teardown is explicit (`GlassHostingController.onRemovedFromParent` → `viewModel.stop()`); the fill
  loop never holds the model across an await. Downloads report `AttachmentDownloadEvent`s and only
  present when the screen is still on top with nothing presented over it. Share/Save in the viewer
  are enabled only once the original has loaded.

## Measurement baseline

The initial attachment investigation (2026-09-02/03, encrypted DMs of roughly
1,800 events) found warm opens near 25 ms, cold filtered discovery around
1.2–1.8 s, and relogin history reaching the start around 20 s with later key
waves. These are historical observations, not current performance guarantees.
The encrypted-media cache fix was verified by thumbnail then original access
returning identical bytes with only one download. Repeat the scenarios below
when changing cache policy, discovery or SDK versions.

## Auto-diagnostics (DEBUG)

For a passive trace of the real UI path, set `ZYNA_ATTACHMENTS_TRACE=1` and leave
`ZYNA_ATTACHMENTS_AUTODIAG` unset. This only enables the `.attachments` log scope: it does not
open a second timeline, paginate, switch tabs or download anything that the visible UI did not
request. Tile logs include task start, cancellation and every cache tier.

Set `ZYNA_ATTACHMENTS_AUTODIAG=1` in the scheme's environment variables. While it is on, tapping a
chat opens it normally and starts `AttachmentsAutoDiagnostics` beside it. This deliberately keeps
the chat's `syncFullHistory` and GRDB writer in the experiment. The probe reproduces the screen's
real cold-start ordering: it starts the source asynchronously and fires the sentinel as soon as
the index makes the content eligible, even if the filtered timeline is still starting.

Console tags attribute the work: `[HistoryPerf]` summarizes the chat's background/demand pagination,
`[trace][filtered]` is the attachments timeline, `[trace][index] trace filtered` is its queued
write/commit, and `trace index mapped` is observation materialisation. The real tile loader starts
on the first 12 visual items as soon as the catalog is published, concurrently with remaining
pagination just as visible grid cells do. The run then checks one forced original (up to 8 MiB),
the viewer lane limit, cache-generation guard and teardown, and ends in the existing
PASS/FAIL/SKIP report and panel dump. Remove the variable to disable the probe.

Runs to collect: cold start → tap; tap again (warm); relogin → tap.

## Measuring by hand

Unit tests (`BlurhashDecoderTests`, `AttachmentThumbnailPlanTests`, `AttachmentTimelineStoreTests`,
`RoomAttachmentsFillTests` — the fill state machine against a fake source)
run on a simulator without a logged-in session. From the command line keep code signing on: with
`CODE_SIGNING_ALLOWED=NO` the host app loses its keychain entitlement, cannot read the SQLCipher
passphrase and traps in `DatabaseService` before any test starts.

SDK-internal logs (e.g. `Lagged` warnings) go to rotated files in the App Group `logs/` dir; to see
them in the Xcode console set the scheme environment variable `ZYNA_RUST_TRACING_STDOUT=1`
(very chatty — also a plausible cause of scroll jank while it is on).

All research logs share one console tag: filter the Xcode console by `[Attachments]` (sub-tags
`[Attachments][diag]` for panel dumps, `[Attachments][viewer]`, `[Attachments][auto]`). The
`ZYNA_ATTACHMENTS_AUTODIAG=1` path enables the `.attachments` scope before constructing the chat;
the normal `LogConfig.enabled` default does not enable it.
In DEBUG the button next to the segmented control opens a diagnostics panel (counts, batch
timings, per-reason fetch sizes, cache tiers, GRDB cross-check, probes, A/B and pause toggles).

What the numbers mean:
- Tile tiers describe UI behaviour: `memory`/`disk` never left the app; `sdk` is a call the tile's
  own producer made; `coalesced` joined another in-flight call (no bytes counted). They undercount
  SDK calls whose owner tile was cancelled, and never see the viewer.
- `sdk calls (producer)` is the authoritative count: `AttachmentFetchMeter` increments right before
  `client.getMedia…`, independent of consumers, with bytes and failures. Whether a call was served
  from the SDK's SQLite media cache or the network is **not visible through the FFI** — `avg ms`
  separates them roughly (tens vs hundreds); the SDK's HTTP tracing is the source of truth.
- `noDiff`: the batch produced no diff within the wait — the normal outcome for a disk chunk without
  attachments in `.onlyMessage`; a late diff is attributed to the next batch.
- Tile `queue` vs `fetch`: `queue` is time waiting for a lane permit; `fetch` is the SDK call.
- `foreign≥`: `.paginating` seen while no fill of ours was running — the chat's `syncFullHistory`
  underneath; a lower bound. The panel's "Pause chat history sync" switch is two-way (cancels or
  restarts the chat's sync below, DEBUG only) so both modes can be measured; unpaused is the real UX.

Scenarios worth repeating on a new build: unencrypted room (all `plainServerThumbnail`); media from
Element without `thumbnail_file` (`deferred` by reason, tap-to-load); files > 20 MiB (re-downloaded
every open under the default retention policy); fresh device + NSE key delivery (banner, retry on
foreground); 300+ tiles under Time Profiler (no ImageIO on main); live insert / redaction / caption
edit (tile appears on top / disappears / stays).

## Attachment-specific fork behavior

Introduced in beta.12 and retained in the linked package:

- **`OnlyMessage` keeps `m.room.encrypted`** (`bindings/matrix-sdk-ffi/src/room/mod.rs`): UTDs get a
  timeline item, the redecryptor's `Set` replaces it, a mismatching msgtype is removed by the
  timeline itself. Permanently undecryptable events stay as UTD rows (their msgtype is unknowable).
  `.sdkOnlyMessage` is the default filter; `.allWithSwiftFilter` stays behind a DEBUG toggle.
- **Encrypted `Thumbnail` requests are normalised to `File`** in `Media::get_media_content` (read,
  write and removal), so thumbnail-then-content on an encrypted source is one download and one
  cache row. Chat bubbles + viewer benefit without Swift changes. Thumbnails cached under the old
  key may download once more. `remove_thumbnail` now uses `thumbnail_source()`. (The send queue
  still writes a second row for its own uploads; Zyna sends directly, so irrelevant here.)

The SDK does not provide an end-to-end pagination/listener barrier. The
client uses a confirming call and bounded settling; neither proves all
late decryptions have arrived.

## Known limits carried into the production UI

SwiftUI grid has no viewport anchoring on live inserts; the derivative disk cache is unbounded;
tiles load in demand order, not visibility order (prefetch is a Texture-UI concern: the source is
ordered, `loadMore` can run ahead of the viewport, and demand tickets make speculative tile loads
cancel cleanly); settling is a heuristic. Chat history now uses the SDK's
`reachedStart`, independently of cached-row availability and late decryption.

## Recommendations (still open)

- **Config** — `setMediaRetentionPolicy(maxFileSize ≈ 64 MiB, maxCacheSize ≈ 600 MiB)` after
  `build()` in `MatrixClientService`, otherwise large photos/videos are never cached.
- **Chat bubbles** — route `MediaCache.loadBubbleImage` through the attachment lanes and demand
  tickets so bubble loads obey the same concurrency and cancellation rules as the grid.

## Persistent attachment index

E2EE Matrix offers neither server-side media search nor server thumbnails, and the SDK has no
persistent index by msgtype (the event cache is a linked chunk without queries; Tantivy search
indexes text only). `roomAttachment` is therefore a small derived projection keyed by
`(roomId, eventId)`. It stores catalog metadata and Matrix media-source JSON, never media bytes and
never a claim that room history is complete.

Both current discovery paths feed it through the same typed mapper and classifier:

- the main chat writes attachments in `TimelineDiffBatcher`'s existing GRDB transaction, including
  late-decryption `.set` updates;
- the filtered attachments timeline writes every attachment it observes, in batches on a utility
  queue;
- migration `v26_roomAttachmentIndex` seeds rows from already-materialised `storedMessage` data.

Upserts are idempotent and merge sparse observations, so a reaction/receipt update with missing
media info cannot erase dimensions, blurhash, thumbnail data, or a resolved sender name. SDK
`clear`, `pop`, `remove`, `truncate` and `reset` describe the in-memory
timeline window, so they never delete catalog rows. An explicit redacted event does. Older
`storedMessage` rows lack blurhash and thumbnail metadata; observing the raw SDK event later
replaces that sparse seed with the full projection.

The screen observes this projection once per room and builds media sources/month groups on a
utility queue, publishing only the ready snapshot on main. Main-timeline SDK mapping and JSON
extraction also run on their own serial queue, outside Texture scrolling. The filtered SDK
timeline is now only a discovery/backfill engine: its pages upsert older
events, while the fill target is measured as growth in unique projection rows, so replaying events
already in GRDB does not count as a newly loaded page. Identical rediscoveries do not write or
republish the room snapshot. Completeness/frontier state remains separate: "these are all
attachments known locally" is useful and honest even when older history has not been requested.

The main chat also persists the SDK's filename/MIME/size, blurhash and animated-image flag.
Standalone and grouped photo/video bubbles decode blurhash off-main; image prefetch no longer
speculates on encrypted originals without a sender thumbnail. Encrypted videos without a sender
thumbnail never use the full video as an image source. Ordinary `m.audio` events render with the
existing file row for now but are indexed as `audio`, distinct from events carrying the Matrix
voice marker.

Still open:

- anchor live inserts when the grid moves to Texture;
- represent UTD coverage/frontier separately from attachment rows;
- catch redactions of old events while neither the chat nor attachments timeline contains them;
- decide the user-triggered history budget independently of `ChatViewModel.syncFullHistory`.
