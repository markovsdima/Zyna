# Room Attachments (Shared Media)

A screen reachable from Room Details ("Attachments") that lists a room's photos/videos and files,
Telegram-style. Built as an R&D iteration to learn how matrix-rust-sdk behaves for attachments in
**encrypted** rooms; measured on real accounts (2026-09-02/03) and kept as the basis for the
production UI. Fast custom UI (Texture) comes later.

## What the screen does

```
Room ──timelineWithConfiguration(.live, filter: .onlyMessage [fork] / .all [A/B])──▶ Timeline
        │ addListener (TimelineDiff)                       │ paginateBackwards(100)
        ▼                                                  ▼
AttachmentTimelineStore (serial queue, rows 1:1 with SDK items)
        │ Snapshot (month groups, newest first, UTD count) — main, leading edge + 50 ms trailing
        ▼
RoomAttachmentsViewModel ──▶ RoomAttachmentsView (SwiftUI in GlassHostingController)
        │ AttachmentThumbnailPlan per tile
        ▼
MediaCache.loadAttachmentThumbnail  (memory → disk → SDK, de-dup by mxc, lanes: 3 thumbnails / 1 original / 2 viewer)
```

Files: `Zyna/SwiftUIScreens/RoomAttachments/*`, `Zyna/Services/Media/AttachmentThumbnailPlan.swift`,
`Zyna/Services/Media/BlurhashDecoder.swift`, `Zyna/Services/Media/AttachmentFetchMeter.swift`,
`Zyna/Services/MediaCache.swift` (Attachments section), `Zyna/UIComponents/QuickLookPresenter.swift`,
`ChatsCoordinator.showRoomAttachments`.

The data source sits behind `AttachmentSource`; `SDKTimelineAttachmentSource` is the only
implementation today. A GRDB-backed one is the likely production replacement (see the end).

## SDK facts (verified in the fork checkout, which matches upstream unless noted)

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
7. **Keys**: backup download on UTD is automatic (`backupDownloadStrategy(.afterDecryptionFailure)`).
   After a relogin keys arrive in waves: the crypto store's `room_keys_received` broadcast has
   capacity 10 (`matrix-sdk-crypto/src/store/crypto_store_wrapper.rs:63`), lags under backup imports
   (`The room key stream lagged`, 6× in 17 s) and the redecryptor then re-scans all in-memory UTDs.
   Self-healing; last decryptions landed 20–45 s after start. Keys received by the NSE are invisible
   to the main process's redecryptor, hence `retryDecryption(sessionIds:)` on foreground; the retry
   only collects session ids of *visible* UTD items (`decryption_retry_task.rs:38-65`). After each
   key wave the redecryptor also re-touches already decrypted events (encryption-info refresh); in a
   message-only timeline that logs one `Set update dropped…` warning per text message — noisy,
   harmless.
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

## Measured (encrypted DM, up to ~1800 events / 54 attachments)

| Scenario | Result |
|---|---|
| Warm re-open | 1 batch, ~25 ms, tiles from memory — at the floor |
| Cold start, `.onlyMessage` | 35–42 disk chunks, 1.2–1.8 s (one network gap fill ≈ 1 s of it), all attachments found, `lateSnapshots` 1–2 |
| Cold start, `.all` (A/B) | 66–80 ms per 100 events (Rust items + 100 `asEvent()`), ~3.4 s for 1505 events; a 600-event text stretch costs 8 batches for nothing |
| Relogin | everything from the network: 440–680 ms batches, 6 fills (5 by budget), room start at ~20 s, 51 late decryptions in waves 1.3 / 5 / 20 / 25 s |
| Relogin, text-heavy room (`!VxxHLV…`) | UTDs climb to 504, decrypt in waves 7–45 s, the SDK removes text decryptions in bulk (`removed=451`); every tile `queue=0ms` with lanes |
| Fork patch 2 | untouched 296 KB original: `getMediaThumbnail` 570 ms (network), then `getMediaContent` 6 ms, identical bytes — one download, one row |
| GRDB coverage | `sdkMedia` = GRDB count and `onlyGRDB=[] onlySDK=[]` on every completed run; 180 stale "Unable to decrypt message" rows in GRDB are a known relogin artefact around call events |
| Lifecycle | `stopped` then `deinit` on every pop; auto-diagnostics 9/9 cold, 9/9 warm, 8/8 relogin |

## Auto-diagnostics (headless, DEBUG)

Set `ZYNA_ATTACHMENTS_AUTODIAG=1` in the scheme's environment variables. While it is on, tapping a
chat in the list does **not** open it: `AttachmentsAutoDiagnostics` runs the pipeline on that room
headlessly and prints `[Attachments][auto]` lines ending in a PASS/FAIL/SKIP report plus the panel
dump. It covers: fill completion (with a tab switch mid-fill), GRDB coverage (skipped when the
chat's mirror is empty, e.g. right after a relogin), the real tile loader on the first 12 visual
items, one forced tap-to-load original (downloads it, up to 8 MiB), the viewer lane limit
(≤ 2 in flight), the cache-generation guard and teardown. The chat is not opened, so there is no
`syncFullHistory` underneath — the numbers are the screen's own cost. Remove the variable to get
the app back.

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
`.attachments` scope is enabled by default in `LogConfig.enabled` (`Zyna/Utils/ScopedLog.swift`).
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

## Done in the fork (`26.5.13-zyna.5-beta.12`, xcframework `zyna-ffi-26.05.13-attachments-utd-media-cache-beta.1`)

- **`OnlyMessage` keeps `m.room.encrypted`** (`bindings/matrix-sdk-ffi/src/room/mod.rs`): UTDs get a
  timeline item, the redecryptor's `Set` replaces it, a mismatching msgtype is removed by the
  timeline itself. Permanently undecryptable events stay as UTD rows (their msgtype is unknowable).
  `.sdkOnlyMessage` is the default filter; `.allWithSwiftFilter` stays behind a DEBUG toggle.
- **Encrypted `Thumbnail` requests are normalised to `File`** in `Media::get_media_content` (read,
  write and removal), so thumbnail-then-content on an encrypted source is one download and one
  cache row. Chat bubbles + viewer benefit without Swift changes. Thumbnails cached under the old
  key may download once more. `remove_thumbnail` now uses `thumbnail_source()`. (The send queue
  still writes a second row for its own uploads; Zyna sends directly, so irrelevant here.)

Analysed with the fork maintainers and deliberately **not** changed: a pipeline barrier so
`paginate_backwards` awaits the timeline's own diffs (design change across two crates, needs
`Lagged`/closed-task handling, does not cover the FFI hop); aligning the returned `bool` with the
skip count (cheap and upstream-friendly, unnecessary for us thanks to the confirming call); raising
the event-cache (32) and room-key (10) broadcast capacities (the first never overflowed here, the
second is not that simple). The client-side settling + confirming call cover the gap.

## Known limits carried into the production UI

SwiftUI grid has no viewport anchoring on live inserts; the derivative disk cache is unbounded;
tiles load in demand order, not visibility order (prefetch is a Texture-UI concern: the source is
ordered, `loadMore` can run ahead of the viewport, and demand tickets make speculative tile loads
cancel cleanly); settling is a heuristic; `syncFullHistory` in the chat stops on row-count
stagnation, not on reconciling existing rows.

## Recommendations (still open)

- **Config** — `setMediaRetentionPolicy(maxFileSize ≈ 64 MiB, maxCacheSize ≈ 600 MiB)` after
  `build()` in `MatrixClientService`, otherwise large photos/videos are never cached.
- **Chat bubbles** — route `MediaCache.loadBubbleImage` through the attachment lanes and demand
  tickets so bubble loads obey the same concurrency and cancellation rules as the grid.

## Production path (likely): a client-side index in GRDB, fed by the SDK

E2EE Matrix offers neither server-side media search nor server thumbnails, and the SDK has no
persistent index by msgtype (the event cache is a linked chunk without queries; Tantivy search
indexes text only). A persistent local index is the only way to open "Attachments" instantly and
offline for rooms the chat never opened. `storedMessage` already holds type, sources, dimensions,
mime, filename, size, timestamp and an index on `(roomId, timestamp)`.

Verified: late decryption already reaches GRDB — a `.set` for a known eventId rewrites the row,
`contentType` included (`TimelineDiffBatcher.swift:722-769`, redacted excepted) — but only while
the chat's live timeline runs. History backfill is `ChatViewModel.syncFullHistory` (`:4491`).

Needed for that path:
- `contentBlurhash` column and mapping in `TimelineService.contentFromMessageType` (also gives
  chat bubbles a placeholder).
- A distinct `contentType = "utd"` (+ session id, cause) instead of text "Unable to decrypt message";
  otherwise pending counts and `retryDecryption(sessionIds:)` are impossible.
- Thumbnail dimensions/size; the encrypted flag can be derived from the stored JSON.
- `GRDBAttachmentSource`: `ValueObservation` on `(roomId, contentType, timestamp)`, paged like
  `ChatViewModel.updateSearchQuery` (`:4424`).
- Backfill for rooms never opened: the SDK timeline from this iteration as the engine.
- Rows updated by late decryption while the chat is closed: keep a background timeline or
  re-open the room — measure how often it matters.

Current measurements say the `.onlyMessage` timeline alone is fast enough for rooms the chat has
synced; the GRDB index matters for instant opening of rooms it has not.
