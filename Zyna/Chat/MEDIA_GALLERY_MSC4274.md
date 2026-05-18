# Matrix Media Galleries

Short future note for MSC4274, "Inline media galleries via msgtypes".

## Status

As of 2026-05-18, MSC4274 is still an open/unstable proposal, not a stable
Matrix message shape. The latest stable Matrix spec does not list a gallery
msgtype under `m.room.message`.

Matrix Rust SDK has experimental gallery support behind `unstable-msc4274`.
Zyna's generated Swift bindings already include `MessageType.gallery`,
`GalleryMessageContent`, `GalleryItemType`, and timeline `sendGallery(...)`.
That is useful to know, but timeline `sendGallery(...)` is not Zyna's durable
direct outbox path.

References:

- https://github.com/matrix-org/matrix-spec-proposals/pull/4274
- https://spec.matrix.org/proposals/
- https://matrix-org.github.io/matrix-rust-sdk/src/matrix_sdk_ui/timeline/mod.rs.html

## Current Decision

Keep Zyna's current photo-group model for production:

- every photo is a normal image event;
- visible caption text remains normal Matrix caption text;
- Zyna metadata only controls grouping and caption placement;
- other clients still see the photos and captions without gallery support;
- Zyna can still handle per-photo delete/reflow semantics.

This is a compatibility choice, not a rejection of Matrix galleries.

## Revisit When

Reconsider gallery events when:

- MSC4274 or a successor stabilizes;
- important clients have acceptable fallback behavior;
- Matrix Rust SDK exposes a Room-level direct gallery helper with caller
  transaction id and returned event id;
- Zyna product semantics are clear for per-item delete versus
  whole-gallery delete.
