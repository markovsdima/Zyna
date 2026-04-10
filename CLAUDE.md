# Zyna — Instructions for Claude

## Architecture
- iOS messenger on top of matrix-rust-sdk via FFI (typed path)
- UI: AsyncDisplayKit (Texture) throughout chat & lists
- Persistence: GRDB as the UI source of truth; SDK Timeline diffs
  flow into GRDB via TimelineDiffBatcher
- Custom Zyna features travel via formatted_body HTML carrier
  (see Messaging/ZynaHTMLCodec)

## Performance principles

This is a high-performance messenger. One of the core mindsets:
**don't lose Texture's advantages** — study its APIs, understand
what each one gives you, and lean on them rather than
side-stepping into vanilla UIKit.

**Main thread is sacred.** Anything that can run off-main should
run off-main. That includes DB reads, JSON/text parsing, image
decoding, model construction, sort/merge, and anything else that
isn't strictly a UIKit call. Treat `DispatchQueue.main` as
precious budget — spend it only on the actual UI mutation step.

Texture-way is the default for anything rendered in cells:
- Prefer `ASImageNode` with shared cached `UIImage`s over per-cell
  `draw(_:withParameters:)` Core Graphics. Texture does not recycle
  cells like UIKit — it creates a new ASCellNode per index path
  and does not recycle them. Nodes are deallocated only when
  removed from the container (via deletion or reloadData). A
  custom `draw()` fires on every new node, which adds up during
  rapid scrolling. A shared `UIImage` costs zero per node: just
  a pointer to the same CGImage. Tint via `imageModificationBlock`
  or template-rendering + `tintColor` for per-cell colour
  variations.
- `draw(_:withParameters:isCancelled:isRasterizing:)` is a valid
  Texture API for async rendering, but it's the right tool only
  when the drawing is genuinely per-instance (unique content).
- Never use UIView subclasses for drawing inside cell bodies —
  they'd pull rendering onto the main thread.
- Use `ASImageNode` for raster images, `ASTextNode` for text.
- `CABasicAnimation` on layer transforms for runtime animation;
  it runs on the GPU compositor and is cheap.
- Background thread for pixel data (Texture), GPU for compositing.
- Avoid main-thread CGContext drawing in scrolling paths.

## Threading with Texture

Texture calls some delegate methods on background queues
**on purpose** — it gives you free concurrency so main stays
smooth. Examples: `willBeginBatchFetchWith`,
`nodeBlockForRowAt`, batch-fetch hooks, preloading callbacks.

Rule for those entry points:
1. Keep the heavy work (DB queries, parsing, model building,
   merge/sort) on the bg queue Texture hands you.
2. Marshal to main **only** for the UIKit-touching step:
   table updates, `performBatchAnimated`, cell mutations,
   observable state the UI subscribes to.

Anti-pattern: wrapping the whole handler in
`DispatchQueue.main.async { … }` — that throws away the bg
capacity Texture gave you and moves GRDB reads to main. Split
the work instead: bg query → (result) → main apply.

## Pitfalls / lessons learned

- **`UIImage(systemName:)` returns nil off-main.** Texture
  creates cell nodes on background threads, so SF Symbol
  images built inline in `init()` will silently be nil. Use
  `AppIcon` (pre-rendered `static let` via
  `UIGraphicsImageRenderer`) to create images once on main
  and share them across cells. Same applies to any UIKit API
  that requires main thread.
- **Never use self-rescheduling `DispatchQueue.main.async`
  loops** to "wait until X is ready". They burn CPU if the
  condition never flips. Use proper lifecycle hooks instead
  (`didLoad()`, observation, closures called by framework).
- **ASDisplayNode `init()` runs off-main**; `didLoad()` fires
  when the backing UIView/CALayer is loaded. Put gesture
  recognisers, `view`/`layer` configuration, and anything
  that touches UIKit into `didLoad()`, never `init()`.
- **`SDK uniqueId` is not stable across Timeline recreation**
  (opening/closing a chat gives the same event a new
  `uniqueId`). TimelineDiffBatcher relies on collision
  resolution by `eventId` for correctness.

## Code style
- Documentation comments ~72 chars wide (reads well side-by-side)
- ScopedLog (ScopedLog.swift) for all logging — pick a scope
  (.timeline, .database, .ui, etc.)
- Prefer small pure functions + enums over class hierarchies
- Tests: Swift Testing framework in ZynaTests target

## Git / PR conventions
- Commit messages: conventional style (`feat:`, `fix:`, `chore:`,
  `refactor:`, `perf:`, `docs:`)
- Commit title ≤ 72 chars; body optional but welcome for context
- Commit body: do NOT hard-wrap at 72 chars. Break lines naturally
  at sentence boundaries for readability, not at a fixed column.
- Commit body length follows the work, not a quota: include every
  load-bearing piece of context (the *why*, the non-obvious trade-offs,
  the edge cases that motivated a design) but no filler. The diff
  shows *what* changed — the body explains what the diff can't.
  A two-line tweak gets two lines; a subtle refactor gets a long body.
- PR titles do NOT use conventional prefixes — just a clear
  human-readable title (GitHub categorises PRs via labels/status)
- PR descriptions are markdown rendered by GitHub — do NOT wrap
  paragraphs at 72 chars there. Let GitHub handle reflow.
  (The 72-char rule is for source-file comments only.)

## Matrix SDK constraints
- Using typed `timeline.send(msg:)` path — gives SendHandle with
  `.abort()` and SDK-native retry/queue for free
- `sendRaw` is NOT used for user messages (no cancel, no retry)
- Custom event data rides in `formatted_body` as hidden
  `<span data-zyna="{...}"></span>` — Zyna parses raw event JSON
  (bypassing SDK's HTML sanitiser); other clients render only body
- See ZynaMessageAttributes + ZynaHTMLCodec for the extensible
  attribute system

## File organization
- `Chat/` — UI (ChatView, cells, input nodes)
- `Core/` — infrastructure utilities (Concurrency, Network, Theme)
- `Messaging/` — Zyna-specific domain (attributes, codec, sender)
- `Services/` — SDK-facing services (MatrixClient, Timeline, Rooms)
- `Services/Database/` — GRDB layer

## Git behaviour
- User commits manually; Claude does NOT commit unless asked

## On breaking these rules
Every rule above is breakable — but not silently. If you believe
a specific case warrants a deviation, stop and ask first, with:
  1. Which rule you want to bend and why
  2. Concrete evidence that the deviation doesn't hurt (e.g.
     "UIView here is fine: the view is static, outside scroll
     paths, and avoids a wrapper node for trivial drawing")
  3. What you gain (simplicity, readability, fewer files)

Never bend a rule without user confirmation. When in doubt,
default to the stricter option.
