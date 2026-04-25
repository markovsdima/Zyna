# Chat Media Grouping

This note explains what we built for photo attachments, why it works
this way, and how it should behave in Zyna and in other Matrix
clients.

## What We Built

Photo attachments now use a dedicated composer sheet instead of living
in the input bar.

That sheet is the single place where the user can:

- see the selected or pasted photos
- reorder them
- remove them
- write one shared caption
- move the caption above or below the media

This works for both:

- a single photo
- multiple photos sent as one visual group

Clipboard paste is part of the same flow. If the user pastes one or
more images into the chat input, those images go into the photo sheet
instead of appearing as small previews in the input bar.

## Why It Works This Way

We wanted one clear media flow.

The sheet is explicit and gives enough space for ordering, captioning,
and previewing the final result.

We also wanted grouped photos to degrade safely outside Zyna.

Matrix does not give us a real album or grouped-media API here, so
every photo is still sent as its own normal event. The grouping is a
Zyna presentation layer on top of that.

The important decision is this:

- the visible caption is stored as a normal Matrix caption on every
  photo in the group
- Zyna metadata is used only to describe grouping and caption placement

We do it this way so the user-visible caption is not lost in other
clients, and so the caption can survive even if one photo in the group
is missing or delayed.

## How It Works

When the user sends multiple photos, Zyna gives them a shared
`mediaGroup` metadata block.

That metadata carries:

- a group id
- each photo's order inside the group
- the intended group size
- the caption placement, top or bottom

For a normal multi-photo send, all photos share the same group id and
the same visible caption.

For a single photo:

- bottom caption works as a normal image message
- top caption also stores Zyna metadata, because placement is a
  Zyna-only rendering rule

On receive, Zyna looks at adjacent photo events from the same sender
with the same group id and decides whether it is safe to render them as
one grouped bubble.

If everything is consistent, Zyna shows:

- one grouped photo bubble
- one shared caption
- the caption above or below the bubble, depending on placement

If the data is incomplete or inconsistent, Zyna fails open and shows
regular individual photo messages instead of hiding content.

That is intentional. User-visible text should never disappear just
because grouping metadata is missing or partially wrong.

## Local Echo And Sync

Grouped photos are slightly harder than normal messages because the
Matrix SDK gives us local echo and synced events as separate stages.

To keep the sender UI stable, Zyna now uses a dedicated outgoing layer
instead of rendering photo groups directly from transient Matrix local
echo rows.

In practice this means:

- the sender bubble is rendered from Zyna's persistent local outgoing
  state
- Matrix send queue is still used for transport state such as
  `transactionId`, upload progress, retries, and final `eventId`
- the outgoing bubble retires only after the final timeline messages
  are matched and hydrated

The goal is simple: a freshly sent photo group should already look like
its final grouped shape, without obvious flicker or collapsing back
into unrelated bubbles.

More detail lives in [OUTGOING_LAYER.md](./OUTGOING_LAYER.md).

## Other Matrix Clients

Other clients do not know anything about Zyna photo grouping.

That is okay.

In other clients, the same send will usually look like:

- photo
- photo
- photo
- with the same caption repeated under each one

That fallback is acceptable for now. It is not as polished, but it is
safe:

- the photos are still there
- the caption is still there
- no important text depends on hidden Zyna metadata

Other clients also ignore caption placement. `Top` and `bottom` are
purely a Zyna rendering choice.
