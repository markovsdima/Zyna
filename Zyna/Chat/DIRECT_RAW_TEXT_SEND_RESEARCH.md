# Direct Raw Outgoing Architecture Research

This is a handoff note for Zyna's outgoing chat architecture work. It is meant
for future chats and for people joining the project, not as polished product
documentation. Keep `OUTGOING_LAYER.md` separate until this design fully
settles.

## Short Version

Zyna is moving outgoing chat writes away from the Matrix Rust SDK local echo and
SDK retry queue. The direction is:

1. Zyna stores the user's outgoing intent in its own encrypted database.
2. Zyna generates and persists the Matrix transaction id before transport.
3. Zyna calls a direct Matrix send API with that transaction id.
4. The Swift binding returns the final Matrix event id immediately after
   transport accept.
5. Zyna stores that event id and reconciles UI state by event id when sync later
   materializes the event.

This gives us deterministic binding across concurrency, app restart, network
loss, and repeated sends with the same transaction id.

Current status: text-like events are on the new path. Media is the next major
research area.

## Why This Exists

The old text path depended on the SDK timeline local echo:

- Zyna created an outgoing envelope.
- `TimelineService.sendWithTransaction` waited for SDK
  `newLocalEvent(transactionId)`.
- `LocalEventTransactionBroker` assigned the next SDK transaction id to the
  first waiter.

That FIFO binding is not strong enough under concurrency or restart. Identical
parallel sends, or a crash between SDK accept and local echo observation, can
leave the UI with duplicate events or stuck `sending` bubbles.

The new path makes Zyna's database the source of truth for outgoing intent and
uses the Matrix event id returned by transport as the bind point.

## SDK/FFI Fact

The forked Matrix Rust SDK Swift binding exposes a direct send with a caller
provided transaction id:

```swift
let eventId = try await room.sendRawWithTransactionIdReturningEventId(
    eventType: "m.room.message",
    content: json,
    transactionId: tx
)
```

This is callable from Zyna Swift without manual C/FFI work.

Important: the returned `eventId` is the reliable bind point. The custom content
marker `com.zyna.client_txn_id` is diagnostic metadata only. Do not depend on
sync returning that marker; diagnostics showed synced direct raw text events can
arrive without it.

## Feature Flag

Direct raw is enabled by default.

Kill switch:

```text
ZYNA_DIRECT_RAW_TEXT_SEND=0
```

`DirectRawTextSender.isEnabled` also checks the UserDefaults key:

```text
com.zyna.matrix.directRawTextSend.enabled
```

Keep the kill switch while the direct architecture is still being expanded to
media.

## Implemented Direct Operations

### Text And Replies

Main files:

- `DirectRawTextSender`
- `OutgoingTextOutboxService`
- `OutgoingEnvelopeService`
- `ChatViewModel.sendOutgoingText`

Behavior:

- Zyna creates an outgoing envelope before transport.
- The envelope item stores the generated transaction id.
- `OutgoingTextOutboxService` sends `m.room.message` through
  `Room.sendRawWithTransactionIdReturningEventId`.
- On accepted transport, the outbox stores the returned event id on the
  envelope.
- Sync later retires the pending UI envelope by event id.
- `.queued`, `.sending`, and `.retrying` text envelopes are resumed by the app
  level outbox when the Matrix client reaches `.syncing`; opening the chat is
  not required for transport retry.
- Replies use raw `m.relates_to.m.in_reply_to` and include Matrix reply
  fallback text/HTML.
- Zyna color attributes are embedded in `formatted_body` through
  `ZynaHTMLCodec`.

### Edits

Main files:

- `DirectRawTextSender.sendEdit`
- `PendingMessageEditService`
- `OutgoingEditOutboxService`
- `ChatViewModel.sendMessage` edit branch

Behavior:

- The edited text and Zyna attributes are stored on the existing
  `storedMessage` row as pending edit state.
- The edit outbox sends an `m.room.message` replacement event through direct
  raw with a durable transaction id.
- On accepted transport, Zyna stores the returned edit event id and updates the
  local row optimistically.
- Retryable transport failures stay pending and are retried with backoff.
- Terminal failures mark the edit failed and publish a user-visible failure
  path.

### Redactions / Deletes

Main files:

- `DirectRawTextSender.sendRedaction`
- `PendingRedactionService`
- `OutgoingRedactionOutboxService`
- `ChatViewModel.redact...`

Behavior:

- Zyna stores a persistent redaction intent.
- If the target has a real event id, the redaction is sent through direct raw
  `m.room.redaction` with a durable transaction id.
- The returned redaction event id is persisted when available.
- Retryable transport failures are retried by the app-level outbox.
- Old fallback paths remain for cases where only an SDK item identifier is
  available.
- UI delete animation still uses the original message snapshot. A lightweight
  pending-delete placeholder is delayed so the normal paint splash animation can
  finish first.

### Reactions

Main files:

- `DirectRawTextSender.sendReaction`
- `PendingReactionService`
- `OutgoingReactionOutboxService`
- `ChatViewModel.toggleReaction`
- `ReactionsNode`

Behavior:

- Adding a reaction stores a durable `pendingReaction` row and sends
  `m.reaction` through direct raw.
- Accepted add stores the returned reaction event id.
- Removing one of our direct-raw-created reactions redacts that stored reaction
  event id through the same direct redaction path.
- Pending removal keeps the reaction pill visible but removes the own-reaction
  highlight and lowers emoji alpha. This avoids changing counts before sync and
  avoids spinner/animation work.

Important limitation:

- Swift SDK reaction aggregation currently exposes sender/timestamp data, not
  each reaction event id.
- Therefore direct raw removal is reliable only for reactions whose event id
  Zyna has stored from its own direct raw add.
- Removing older own reactions falls back to `Timeline.toggleReaction` until an
  SDK/FFI API exposes reaction event ids or another reliable mapping.

## Proven Behavior

Tested successfully:

- plain text send;
- colored text send;
- reply send, including colored replies;
- edit send;
- redaction/delete send;
- reaction add/remove;
- E2EE encrypted rooms;
- group rooms, not only DM rooms;
- five identical text messages sent quickly;
- offline send, network restore, and retry;
- offline send, app kill, relaunch, network restore, and retry;
- crash after outgoing envelope creation;
- crash after transport accept;
- duplicate prevention by Matrix transaction id idempotency.

Key conclusion: Matrix transaction id idempotency plus the returned event id is
enough for deterministic binding on the direct path. The custom content marker
is useful only for logs/diagnostics.

## Current Non-Media Gaps

The non-media path is good enough to continue building on it, but these cleanup
items remain:

- Rename `DirectRawTextSender` to something broader, for example
  `DirectRawEventSender`.
- Factor duplicated outbox retry/scan code across text/edit/redaction/reaction.
- Decide how long to keep the direct raw kill switch.
- Decide whether direct text should preserve old markdown behavior or keep
  plain `m.text` for now.
- Decide whether old direct raw diagnostic markers should remain in encrypted
  event content.
- Clean up old fallback branches once media is also migrated and the kill
  switch policy is clear.

## What Still Uses The Old SDK Timeline Send Path

Media still depends on SDK timeline send and SDK local echo binding:

- image;
- video;
- voice;
- file;
- media batch / photo groups;
- forwarded media.

These paths still call SDK APIs such as `timeline.sendImage`,
`timeline.sendVideo`, `timeline.sendVoiceMessage`, and `timeline.sendFile`, then
bind through `sendWithTransaction` / `LocalEventTransactionBroker`.

## Media Research Plan

Media is harder than text-like events because all Zyna rooms are encrypted. We
cannot safely send plaintext `m.image` / `m.file` JSON after uploading bytes.
For encrypted media, the SDK currently handles:

- encrypting original media bytes;
- encrypting thumbnails;
- uploading encrypted bytes to the homeserver;
- producing Matrix encrypted file metadata (`file`, `thumbnail_file`, keys,
  IVs, hashes, sizes, mimetypes, blurhash, duration, waveform, etc.);
- sending the final room message event through the encrypted room pipeline.

### Preferred Research Direction

Look for or add a Matrix Rust SDK / Swift FFI method that keeps SDK-owned media
encryption/upload, but lets Zyna provide the transaction id and receive the
final event id.

Ideal shape:

```swift
let eventId = try await room.sendImageWithTransactionIdReturningEventId(
    params: params,
    thumbnailSource: thumbnailSource,
    imageInfo: imageInfo,
    transactionId: tx
)
```

Equivalent methods may be needed for video, voice/audio, file, and maybe a
generic media send.

Why this is preferred:

- SDK keeps the complicated encrypted media upload behavior.
- Zyna gets durable transaction ids and immediate event-id binding.
- The migration stays close to the successful text/edit/redaction/reaction
  pattern.

### Alternative Research Direction

Use lower-level SDK APIs to upload encrypted media first, then send the final
event via `sendRawWithTransactionIdReturningEventId`.

This gives Zyna more control, but it is riskier:

- we must verify the SDK exposes the exact encrypted upload primitives in Swift;
- we must build Matrix media event JSON correctly for every media type;
- retries may create orphaned encrypted uploads unless we persist upload
  results and garbage-collect carefully;
- metadata parity with SDK timeline sends becomes our responsibility.

Treat this as a fallback if direct media send with custom transaction id is not
practical.

### Durable Media Storage Requirement

Before media can be fully direct/durable, outgoing files must be stored before
transport in app-owned protected storage, not only temporary files. The outbox
must be able to retry after app restart.

Minimum durable media record needs:

- room id and envelope id;
- item index for batches;
- media kind;
- local protected original file path;
- local protected thumbnail path when applicable;
- caption and reply info;
- Zyna attributes and media-group metadata;
- generated transaction id;
- returned final event id;
- retry state and attempt metadata.

The first version can re-upload media on retry. That may leave orphaned uploads
server-side, but keeps the model simple. A later version can persist encrypted
upload results if the SDK exposes them cleanly.

### Suggested Media Migration Order

1. Research SDK/FFI media APIs and choose between the preferred and alternative
   paths.
2. Implement durable image send first. Images cover original + thumbnail +
   caption + optional reply + Zyna color/group metadata.
3. Add file send. Files are usually simpler than video/voice.
4. Add voice send, including duration and waveform.
5. Add video send, including thumbnail, duration, dimensions, mimetype, size,
   and blurhash.
6. Add media batch/photo groups on top of the individual durable media items.
7. Add forwarded media once normal media sends are stable.

## Cleanup Plan After Media

Once media has a durable direct path too, remove or shrink the old SDK local
echo bridge:

- `TimelineService.sendWithTransaction`;
- `LocalEventTransactionBroker`;
- reliance on SDK `newLocalEvent` for outgoing binding;
- content/timestamp heuristics for outgoing correlation;
- old timeline-send fallbacks where direct raw has complete parity;
- duplicated pending/outbox implementations if a shared outbox abstraction is
  worth it.

Do this after media, not before. Until then, the old bridge is still needed for
media sends and some fallback cases.

## Manual Test Checklist

For each operation that moves to the direct architecture, test:

- online send;
- offline send, then restore network;
- offline send, kill app, relaunch, restore network;
- kill after pending intent is stored but before transport accept;
- repeated identical sends;
- group room;
- receiving device view;
- Element or another Matrix client when event shape matters.

Useful log filters:

```text
DirectRawTx
DirectRawEditTx
DirectRawRedactionTx
DirectRawReactionTx
outbox
```

## Commit Hygiene Notes

This file is a research/handoff note. It can stay untracked while the work is
moving quickly, but it is useful to commit at a milestone so future chats do not
depend on memory.

Do not include unrelated local changes unless intentional:

- Xcode signing/profile changes in `Zyna.xcodeproj/project.pbxproj`;
- global logging changes such as `LogConfig.enabled = .all`.
