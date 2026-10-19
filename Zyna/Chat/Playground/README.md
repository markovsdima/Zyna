# Chat list playground

Container comparisons are available in Debug and Performance builds.
Collection is the full chat in every configuration. Custom remains a
separate prototype. Ordinary Release excludes the picker and playground.

## Open a chat

1. In Settings → Diagnostics, enable **Chat list playground**.
2. Tap a chat and choose **Collection · Full chat** or **Custom · Playground**.
3. Go back to the room list to open another implementation.

Without the picker, opening a chat goes directly to the full Collection screen.
Only the selected screen is instantiated. Each screen uses
its own normal ChatViewModel, including its history-sync policy, and
the existing asynchronous GRDB page loader. Pages are prefetched in both
directions. Custom does not add a separate server batch-fetch loop;
history arriving through the normal view model remains available locally.

The full Collection chat uses the existing cell factory, reply indicator,
message actions, attachment viewers, sending, read receipts, sticky dates,
keyboard handling, and menu restoration.

Custom uses the actual message cell classes, shared per-role
portal gradients, GlassNavBar, GlassInputBar, and ContextMenuController.
The input bar's scroll-to-latest button uses its normal Metal rendering,
animation, and expanded capture area. It appears after
scrolling 1.5 screens away with more than 20 messages, or whenever the loaded
window has newer history outside it. Tapping returns to the latest rows;
local edits are retained when no history jump is needed.
Reply-header navigation and reply swipe are connected. The composer adds
local text rows; it does not send messages. Opening attachment viewers,
production message actions, read receipts, and the sticky date overlay are
outside this experiment.

## Custom experiments while moving

Tap the title or attach button to open the experiment menu:

- Jump to the oldest stored message or back to the latest messages.
- Schedule 30 earlier or newer local rows, then drag or flick before the
  two-second delay expires.
- Schedule a visible bubble resize or removal during a drag or deceleration.
- Reset local edits to resume displaying view-model snapshots.

Long-press a bubble to exercise extraction and animated return under glass.
The menu also provides local resizing and removal. Local edits freeze the
displayed datasource until reset or a history jump; they never change GRDB.
Background history sync follows the same policy as the ordinary chat.

Compare a downloaded chat in both directions, including a distant reply
jump followed by scrolling toward newer messages. Check the top and bottom
glass, text/media, keyboard appearance, and menu cancellation.

For performance comparisons, use the same chat, device, build configuration,
and history-sync setting. Disable CHAT_PAGING_TRACE and other profiling
flags first. The playground adds no continuous console logging or FPS HUD.
Its scroll booster runs during deceleration, as in the production chat.

## Optimized device profiling

1. Select the shared **Zyna Performance** scheme and a physical iPhone.
2. Choose **Product → Profile** (Cmd-I), then the Animation Hitches template.
3. Enable **Settings → Diagnostics → Chat list playground**, then open the
   same chat with each container. Record active scrolling separately from
   screen changes, menus, and idle time.
4. Keep **Pause chat history sync** in that same settings section identical
   across runs. Off includes normal history sync; on isolates local scrolling.
   The switch shares its stored value with the Debug attachments panel.

The Performance configuration copies Release settings and explicitly uses
Swift `-O` with whole-module compilation. It retains dSYM debug symbols for
Instruments. App code coverage is disabled in the configuration and is not
enabled by the scheme. The preview/debug dylib is disabled as well.
Only the app target defines `CHAT_LIST_PLAYGROUND`; `DEBUG` is not defined,
so Debug-only logging, paging traces, glass profiling hooks, and attachment
auto-diagnostics are excluded. Glass uses its Release path with the
additional capture interpolation comparison switch below.

The scheme's Run action also uses Performance, without attaching LLDB.
Tests use Debug and Archive uses ordinary Release. The original Zyna scheme
and its Debug/Release configurations are unchanged. Performance uses the
same bundle ID and local database as the regular app.

Compare first-pass scrolling separately from revisiting prepared content.
Repeat each scenario and vary the order of containers. Keep the theme,
scroll-to-latest button visibility, and glass configuration consistent.
The resulting device traces, not simulator test timings, determine whether
an experiment improves performance.

### Capture interpolation

**Settings → Diagnostics → Glass capture interpolation** switches between
**Low** and **Default** without rebuilding or restarting. Low is initially
enabled; the selected value persists between launches. The switch is
available in Debug and Performance and affects both chat containers.
Ordinary Release always uses Low.

Low sets `CGContext.interpolationQuality = .low` while capturing the glass
backdrop. The surrounding save/restore restores the context's original
quality afterward, including when reusing buffers in Default mode. The
setting is held in memory; capture ticks do not read UserDefaults.
Capture dimensions, cadence, layer geometry, and Metal rendering are
unchanged. The source layers themselves are not modified.

Low was retained after device profiling showed less resampling work in
capture, with no visual difference observed in the checked scenarios.
This remains a rendering hint, not a guaranteed speedup for every frame.
For further comparisons, use the same container, reply jump, and return
scroll. Label each recording with the container and quality.
Check text, photos, bubble edges under both glass bars, reply swipe, and
context-menu opening/return for visual changes. A repeat in reversed order
helps separate the setting from cache warming.

## Implementations

### Collection in the full chat

`ChatMessageList` connects the existing controller to `ASCollectionNode`.
`ChatCollectionLayout` uses Texture's already measured, committed element
map. The layout facilitator samples the old geometry and current offset
immediately before the UIKit batch, after asynchronous preparation.
The layout returns the compensated offset through
`targetContentOffset(forProposedContentOffset:)`. The target is cleared when
the batch finishes. The real message node is the collection cell; there is
no playground row wrapper or second measurement pipeline.

Late height changes use the public `contentOffsetAdjustment` invalidation
property. The full chat keeps newest-first, inverted coordinates. It does
not access private UIKit scrolling fields. The former Table backend and
standalone Collection prototype have been removed.

### Custom

A hidden UIScrollView supplies the native pan gesture and deceleration.
The visible nodes belong directly to a content node whose bounds origin
tracks the logical offset. This node is also the glass capture source, so
capture still culls individual rows. Ordinary movement does not change row
frames; attachment is reconciled when the visible range or geometry changes.
Logical history coordinates are independent of the scroller's bounded
coordinate range. Native contentSize and contentOffset are assigned only
when their values must change.

Nodes are prepared within three viewport heights on each side and retained
until they leave a six-screen margin. The larger retention band trades
memory for less recreation during reverse scrolling. Detached nodes do not
enter the glass capture hierarchy.

Worker results arrive in small batches. UIKit installation runs through
DisplayLinkDriver, nearest the viewport first: at most four nodes per tick
and a soft time budget of 20% of the display interval, capped at 2 ms. One
node's installation cannot be interrupted and can exceed that budget.
The subscription ends when the ready queue is empty.

Drawing starts ahead of visibility without waiting for rasterization; only
intersecting nodes enter the visible hierarchy. This lets Texture's
hierarchy callbacks follow actual attachment. No private interface-state
callbacks are invoked manually. Very fast cold scrolling can still outrun
preparation or display; compare missing-content frames as well as hitches.

This is an independent prototype inspired by the separation used in
Telegram, not a port of its list implementation. It uses no private UIKit
scrolling symbols. UIKit still owns motion physics.

### Prototype preparation and positioning

Custom uses an off-main measurement queue, a height cache, a thin row
wrapper, and immutable snapshots of actual chat rows. Each newly loaded
or changed row is measured before its snapshot is applied. Custom discards
distant nodes but retains measured heights for loaded history; it does not
yet implement Telegram's measurement of only the nearby portion of a list.

Position is anchored by stable row ID. The anchor is sampled at commit,
preserving finger movement during background preparation. If a visible row
is removed, a surviving visible row or nearby survivor supplies the anchor.
Late size changes update geometry and survive subsequent cached snapshots.

Experimental datasource updates are unanimated. Full insertion/deletion
animations, comprehensive accessibility scrolling, adaptive preloading,
and production feature parity require separate work before adoption.

## Interpreting results

These implementations have different node retention and preparation costs.
Custom uses ordinary top-to-bottom coordinates; the full chat is inverted.
A smoother prototype does not alone establish the cause or prove lower
CPU/GPU cost. Full Collection now runs additional real chat behavior,
so its cost cannot be inferred from earlier standalone prototype traces.

Compare viewport continuity separately from frame stalls and memory usage.
The automated tests cover geometry, actual container updates, late size
changes, repeated batch compensation, Custom retention and overscroll, and
portal/menu restoration through the capture root. Device scrolling with
the real glass is still required before drawing performance conclusions.
