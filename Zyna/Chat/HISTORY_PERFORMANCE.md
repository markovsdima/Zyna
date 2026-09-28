# Compact history diagnostics

Diagnostics are disabled by default. For a Debug reproduction, enable
`.historyPerformance` in `LogConfig` and filter the console by `[HistoryPerf]`.
No scheme changes are needed. Keep `.polls` disabled and `CHAT_PAGING_TRACE`
unset for compact measurements. Enable `.messageDiagnostics` separately
when the metadata probes described below are needed.
Do not enable the SDK's verbose event logs during timing measurements.

A chat starts one account-bound trace (`v=3`). It emits at most two summary lines
every ten seconds, plus a begin line and a final summary on cleanup. Idle
intervals are silent. There is no early line limit, so a long scroll remains
observable. Replaced sessions reject late completions. The recorder keeps
fixed counter sets and at most 128 in-flight spans; `overflow` reports lost
spans if that bound is reached. Logging performs no additional database reads.

## Reproduction

Reproduce with a Debug build on the device:

1. Log in again, open the long chat and keep scrolling toward its beginning.
2. After a noticeable stall, continue normally. There is no need to time a
   manual marker or stop immediately.
3. At the end, wait ten seconds, leave the chat to flush the final interval,
   and copy all `[HistoryPerf]` lines, including `begin` and `end`.

`trace` groups one chat opening; `tMs` is elapsed monotonic time from opening.
Only room/database hashes appear, never messages, event IDs, SQL or key data.

## Progress and state

The first line carries progress and last sampled state. `viewAgeMs` gives
the age of the scroll-side sample (`-1` before the first sample). In
particular, local busy/edge values may be stale after scrolling stops:

- `rows/messages`: current retained display size, not total room history.
- `localOlder`: more raw history remains in the local database.
- `edgeScreens`: screenfuls to the older local edge, sampled while scrolling.
- `localBusy/serverWait/sdkBusy`: local loading, UI waiting for server history,
  and pagination busy state (the view sample includes the writer drain).
  `sdkStart` counts SDK results reporting the start of history.
  `state[exhausted]` now follows that result, never a local empty-read timeout.
- `background/demand`: background and UI requests for a shared page.
  `pageJoined` counts callers joining an existing SDK call/writer drain.
  `sdkMissing` counts attempts without a ready SDK timeline.
- `pageRaw/pageShown`: raw records read versus admitted records in local page
  attempts. These are not unique events and include superseded reads.
  `pageRedacted` counts admitted tombstones that normally produce no bubble;
  it explains pages that advance the raw cursor without adding visible rows.
  `pageEmpty` means no admitted rows, including an exhausted raw page.
- `refreshes/unchanged/refreshStale/pageStale`: repeated snapshots and work
  discarded because the window advanced while preparation was running.
  `pageStaleWindow/pageStalePresentation` identify changed window bounds or
  changed presentation state; both can count the same rejected page.
- `boundsRefreshes/boundsStale`: repair-only paging-boundary checks and
  checks superseded by a window change or an ordinary notification. They
  read at most one ID on each eligible side, without fetching the retained
  message array. These attempts are separate from full `refreshes`.
- `recoveryPending/recoveryKeys/recoveryProjection/recoveryFailed/recoveryUnknown`:
  Boolean reasons for the recovery notice, sampled from its existing bounded
  observation of up to 201 unresolved records in the whole room. These are
  neither queue sizes nor proof that all older history has been downloaded.
  `recoveryProjection` means inspection resolved a visible event that still
  awaits the ordinary SDK timeline projection.
- `hidden/visible/utd/unknown/inspectError`: inspection outcomes. `visible`
  alone is not an aggregated SDK message; `repairChanges` counts store changes.
  `visibleText/visibleMedia/visiblePoll/visibleZynaCall/visibleCall/visibleOther`
  classify those visible results using a fixed vocabulary. In particular,
  `visibleZynaCall` identifies an embedded call signal that Zyna's ordinary
  mapper excludes despite its SDK-visible message type. `unknownEncrypted`
  and `unknownOther` distinguish indeterminate encrypted events from other
  types. `inspectLegacy` counts inspections of old localized placeholders.
  `[HistoryUnknown]` adds one metadata line per indeterminate event, at most
  eight per chat worker, when `.messageDiagnostics` is enabled. It includes
  hashed identity, attempt number, allowlisted type names, and JSON field
  shapes, never field values. Custom type names are hashed. Sampling uses the
  existing inspection result and adds no SQL or network requests. It does not
  identify the exact Rust classification branch or authorize excluding a row.
  Inspection counts include retries.
  `visibleEmptyText` and `visibleCallInvite` identify the other explicit app
  exclusions; `visibleRTC` separates displayed RTC notifications from the
  remaining `visibleCall` group. Successful exclusions count as
  `repairChanges` while the original SDK disposition remains `visible`.
  Validated `io.element.call.reaction` exclusions retain the SDK outcome
  `unknownOther` and contribute to `repairChanges`; the type name is allowlisted.
- `projectionUTD/projectionMapped/projectionFiltered/projectionRedacted/projectionParseError`:
  a Debug-only comparison of successful, non-excluded inspection with the
  current SDK timeline. Each event is sampled once per chat opening, up to
  32 events (`projectionCapped=1` means the cap was reached). These are unique
  samples, unlike the inspection counters, which include retries. `Mapped`
  means the normal content mapper can produce content from that SDK item;
  it does not prove that the corresponding diff has reached storage yet.
  `projectionAbsent` means outside the current timeline, not proof of removal.
  `projectionError/projectionMismatch/projectionNoTimeline` distinguish a
  failed lookup, inconsistent identity, and an unavailable timeline. This
  adds only bounded in-memory SDK lookups on the serial repair worker; no
  network requests, SQL, new timelines or decryption retries. Sampling follows
  the existing repair schedule and does not reset its persistent backoff.
  Once pagination reports the start of history, a single delayed pass (3 s)
  rechecks the already sampled IDs, at most 32 more memory-only lookups.
  `projectionRecheck*` uses the same categories for this later snapshot. It
  also classifies first samples arriving after this delayed pass. It
  bypasses inspection/backoff, not SDK history loading, and does not claim
  that the SDK's asynchronous pipeline has fully drained. A stopped trace
  rejects further lookups. This avoids treating an early miss during history
  loading as a permanent absence.
- `pending[stage=count:oldestAgeMs]`: unfinished operations, including calls
  that span reporting intervals. This remains visible while main is blocked.

`projectionRetry/projectionRetrySessions` count retry requests and distinct
session IDs supplied, not completed decryptions. The production worker's
selection, pacing and completion rules are documented under
[SDK projection recovery](SCROLL_AND_PAGINATION.md#sdk-projection-recovery).

## Timing stages

The second line reports `stage=count/averageMs/maximumMs/errors`:

| Stage | Boundary measured |
| --- | --- |
| `bounds` | Repair-only queries for raw older/newer history availability |
| `sdk` | Actual backward-pagination API call, including SDK and any network wait |
| `mapQ/map` | Waiting for our diff mapper / running the mapper |
| `writeQ/flush` | Waiting for our serial writer / complete mapped batch |
| `dbR.wait/dbW.wait` | Waiting to enter the account's serial DB connection |
| `dbR/dbW` | DB access through its return, including transaction completion |
| `db.main` | Entire synchronous DB call made from main, including its wait |
| `pageQ/page` | Waiting for history preparation / local page or jump preparation |
| `refreshQ` | Waiting for a full refresh or a repair-only boundary check on the shared worker |
| `refresh` | Reading and normalizing a full window snapshot |
| `prepare` | Background construction of the complete display snapshot |
| `mainQ` | Prepared snapshot waiting to reach main |
| `render` | Main-thread commit, prefetch/timer scheduling, list submission and synchronous UI callbacks |
| `prep.reconcile` | Background identity/redaction reconciliation and partial-deletion state |
| `prep.messages` | Background conversion through the value cache and display filtering |
| `prep.groups` | Background outgoing-envelope assembly, media groups and cluster decoration |
| `prep.rows` | Background row/date-divider construction and navigation indices |
| `prep.diff` | Background identity diff, in-place classification and timer deadlines |
| `texture` | List submission until Texture's completion; includes queueing/main delays |
| `inspect` | SDK event inspection, including possible network/key retrieval work |
| `projectionLookup` | Bounded current-timeline lookup and content classification after successful inspection |
| `repairQ/repairWrite` | Repair's wait for the shared writer / persistence |
| `repairPause` | Deliberate 100 ms pacing plus task rescheduling delay |
| `barrier` | Shared page waiting for mapped diffs and writes already received to drain |

The five `prep.*` phases partition background `prepare`. Synchronous UI callbacks
are included in `render`; Texture completion is measured separately. Other
action/navigation paths can still contribute `db.main`; its absence is not a
whole-app claim. `refreshStale/pageStale` include local presentation invalidation.
See [admission and presentation](SCROLL_AND_PAGINATION.md#admission-before-presentation)
for snapshot consistency and repair refresh coalescing.

Durations overlap and are inclusive, not CPU percentages. Completion samples
are charged to the interval where they finish, even if they began earlier.
DB timings include other work on the same account connection; observers and
callers not using `AccountDatabase` are not independently attributed. A long
`sdk` or `inspect` does not by itself distinguish the server, network, crypto
or SDK internals. Add narrower instrumentation only after this first trace.

`scroll` counts display-link callback gaps only while dragging/decelerating:
`gap32/gap100` and the worst gap in milliseconds. This is a main callback
cadence probe, not a GPU frame-time measurement or proof of dropped frames.
It does not set a preferred frame rate. Per-frame work uses scalar
counters; one aggregate is transferred per second. No cell hooks are added.
`power/thermal` are sampled at each report so power saving and thermal
pressure during a long run are visible alongside the timing changes.
