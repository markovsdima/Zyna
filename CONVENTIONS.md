# Zyna — Conventions & Patterns

Full reference for project conventions, Texture patterns, and
architectural decisions. CLAUDE.md has the critical pitfalls;
this file has the detailed reasoning. Read it when working on
unfamiliar areas.

## Performance

Main thread is sacred. DB reads, parsing, image decoding, model
construction — all off-main. `DispatchQueue.main` only for the
final UI mutation.

Texture-way for anything in cells:
- `ASImageNode` with shared cached `UIImage`s, not per-cell
  `draw()`. Texture doesn't recycle nodes — shared images cost
  zero per node (pointer to same CGImage).
- `draw(_:withParameters:...)` only for genuinely unique content.
- No UIView subclasses inside cell bodies (pulls to main thread).
- `ASImageNode` for images, `ASTextNode` for text.
- `CABasicAnimation` on layer transforms for GPU-composited
  animation.

## Threading with Texture

Texture hands background queues on purpose for
`willBeginBatchFetchWith`, `nodeBlockForRowAt`, batch-fetch
hooks, preloading callbacks. Keep heavy work there; marshal to
main only for the UI mutation step.

Anti-pattern: wrapping the whole handler in
`DispatchQueue.main.async { … }` — throws away bg capacity and
moves GRDB reads to main.

## Room list updates

Diff-based via `performBatchUpdates`, never `reloadData()` for
incremental changes — `reloadData` destroys all visible nodes
and causes a full flash. Presence changes use `reloadRows` only
for affected rows, not a full array replace.

## MediaCache

Two-tier: NSCache (memory, 300 items) → Caches/ directory (disk)
→ SDK fetch. Request deduplication via Task dictionary.

In Texture node init: call `cachedImage(for:)` synchronously
(NSCache is thread-safe) so the node is created with the image
already set — no async flash. Async fallback for disk/network.

## Glass architecture

Renderers live inside GlassNavBar / GlassInputBar as regular
subviews, not in UIWindow (IOSurface-era legacy removed).
GlassAnchor owns the renderer (`let renderer = GlassRenderer()`).
GlassService drives frame + content per tick, doesn't own
placement or z-ordering.

`GlassAnchor.isAnimating` uses `animationKeys()` walk up the
layer chain — not presentation vs model frame comparison (which
always matches due to `convert` walking presentation parents).

## Navigation

`ZynaNavigationController` — not `UINavigationController`. Owns
the stack and slide animations (CASpringAnimation via
`IOS26Spring`: mass 1, stiffness 555.027, damping 47.118,
duration 0.3832s, 120 Hz on ProMotion).

Interactive pop via `InteractiveTransitionGestureRecognizer` with
scroll-conflict detection (walks hit-test chain for horizontally-
scrollable views). `InteractivePopTransition` drives the drag,
bumps `GlassService.setNeedsCapture()` per frame.

Tab bar hide/show uses **frame animation**, not `layer.transform`
— `.systemChromeMaterial` blur uses a private CABackdropLayer
that doesn't follow ancestor transform animations.

Display corner radius via `_displayCornerRadius` KVC (masked
through `DynamicAction`). Corner curve `.continuous` (squircle).
Save/restore original clipsToBounds + cornerRadius per transition.

## Private API masking

Use `DynamicAction.resolve(bytes:mask:)` for selectors and
`DynamicAction.resolveString(bytes:mask:)` for KVC keys.
Encode via `Scripts/encode_selector.py`. Never leave
underscore-prefixed API strings in plaintext.

## Matrix SDK

- Typed `timeline.send(msg:)` path for user messages (gives
  SendHandle with `.abort()` and retry).
- `sendRaw` only for native call invite (`m.call.invite`).
- `sendImage` throws `InvalidAttachmentData` — using `sendFile`
  as workaround. SDK still delivers as `.image` event (detects
  mimetype), but without width/height. Dimensions derived from
  loaded thumbnail and persisted to GRDB.
- Zyna span carrier: `<span data-zyna="{...}">` in
  `formatted_body`. SDK's HTML sanitizer strips it — parse raw
  event JSON directly.
- Voice message temp file: delayed delete (10s) to avoid racing
  with SDK's async upload.

## Code style

- Documentation comments ~72 chars wide.
- ScopedLog for all logging — pick a scope.
- Prefer small pure functions + enums over class hierarchies.

## Git / PR conventions

- Commits: conventional style (`feat:`, `fix:`, `chore:`),
  title ≤ 72 chars.
- Body: natural line breaks (not hard-wrapped at 72), length
  follows the work. The diff shows *what*; the body explains
  *why*.
- PR titles: no conventional prefixes, just clear human-readable
  title. PR descriptions: markdown, no hard-wrap.

## File organization

- `Chat/` — UI (ChatView, cells, input nodes)
- `Core/` — infrastructure (Concurrency, Network, Theme)
- `Messaging/` — Zyna domain (attributes, codec, sender)
- `Services/` — SDK-facing (MatrixClient, Timeline, Rooms)
- `Services/Database/` — GRDB layer
- `Navigation/` — ZynaNavigationController, ZynaTabBarController,
  interactive gesture, spring animations, IOS26Spring
- `Glass/` — Metal glass renderer, GlassService, anchors, bars
