# Zyna — Architecture Decisions

Architectural choices, tradeoffs, and workarounds.

---

## Custom navigation (ZynaNavigationController)

Plain UIViewController owning its own view stack and transition
pipeline. Not a UINavigationController subclass.

**Trigger:** iOS 26 system dim/blur overlay during back-swipe
(`_UIInteractiveHighlightEffectWindow`, no public API to disable).

**What it actually gives:**
- Full control over spring animations (iOS 26 spring tuned to
  stiffness 555.027, damping 47.118 — matches system feel)
- 120 Hz ProMotion via undocumented `highFrameRateReason` KVC hint
  on CASpringAnimation (preferredFrameRateRange alone doesn't work)
- Per-frame glass capture during interactive pop — `setNeedsCapture`
  on every gesture frame keeps Metal glass in sync without CAAnimation
- Smart gesture recognizer: direction gate (10pt buffer before
  committing), scroll ancestor detection (walks hit-test chain for
  UIScrollViews), late hijack (doesn't steal touches until confirmed)
- Synchronous stack state — stack is mutated before animation starts,
  queryable mid-transition
- Tab bar hide/show locked to push/pop with matched spring duration
- No dependency on UIKit transition internals — immune to future
  system changes

---

## Tab bar: frame animation, not transform

`ZynaTabBarController` animates the tab bar's `frame` when
hiding/showing, not `transform`.

**Why:** The tab bar uses system material blur
(`.systemChromeMaterial`). Its internal `CABackdropLayer` operates at
the compositor level and reads position from the committed render
tree. Transform animations don't update that position — the blur
layer stays pinned to the original spot while the visual view moves.
Frame animation changes the actual position in the render tree, so
the blur follows.

---

## Forwarding is entirely a Zyna concept

Matrix has no notion of forwarding — no `forwarded_from` field,
no `is_forwarded` flag. The SDK's `sendForwardedContent` just
re-sends content into another room; recipients see a normal message
from you.

**Decision:** We construct a new message with a Zyna span carrying
`forwardedFrom`. Text — `sendMessage` with attributes. Media —
download and re-upload via `sendFile` with span in `formattedCaption`.

**Why re-upload:** `sendForwardedContent` takes a sealed
`RoomMessageEventContentWithoutRelation` — no way to attach
`formattedCaption`, nowhere to put the span.

**Tradeoffs:** Double homeserver storage, extra bandwidth.
Acceptable for photos and voice. Revisit for video/large files.
**Cleaner path:** Fork SDK to expose `formattedCaption` on forward.

---

## sendFile instead of sendImage

All image sends go through `timeline.sendFile`, not `sendImage`.

**Why:** `sendImage` throws `InvalidAttachmentData` across SDK
versions (25.11.11, 26.04.01). Likely an SDK bug.

**Tradeoff:** Images arrive as `m.file` to other Matrix clients.
Zyna maps content by mimetype so displays them as images regardless.
Thumbnail generation is prepared in MediaPreprocessor but commented
out until the bug is fixed.

---

## Zyna span in formatted_body

All custom metadata (color, forwarded-from, call signaling) rides in
a hidden `<span data-zyna="{...}">` at the end of `formatted_body`
(or `formattedCaption` for media).

**Why:** Matrix has no extensible fields for custom app features.
`formatted_body` survives standard federation. Other clients ignore
the span. The SDK's HTML sanitizer strips `data-zyna`, so we parse
raw event JSON directly.

**Tradeoff:** Parsing raw JSON on every event instead of using the
SDK's typed API.
