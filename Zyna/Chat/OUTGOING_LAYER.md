# Chat Outgoing Layer

This document describes the current outgoing chat architecture in Zyna.

The important change: chat outgoing delivery no longer depends on Matrix Rust
SDK timeline local echo or the SDK send queue. Zyna owns durable outgoing
intent, retry policy, and UI render state. Matrix still owns encryption,
transport, server acceptance, sync, and final timeline truth.

## Core Model

For every outgoing chat operation:

1. Zyna stores the user's intent in its encrypted local database before
   transport starts.
2. Zyna creates and stores a stable Matrix transaction id before transport
   starts.
3. An app-level outbox sends the operation through a direct Room-level SDK API
   using that transaction id.
4. The SDK binding returns the accepted Matrix event id.
5. Zyna stores the returned event id and binds the local outgoing item to the
   server event.
6. Later sync materializes the event in the normal timeline, and the outgoing
   envelope retires by event id.

The transaction id gives idempotent retry. The returned event id is the reliable
bind point. Custom Matrix content markers are diagnostic metadata only.

## Why This Exists

The old text path waited for SDK local echo and associated the next emitted
local transaction id with the first waiter. That FIFO-style binding was fragile
under concurrency, app restart, identical parallel sends, and crashes between
SDK accept and local echo observation.

The new path removes that gap. A bubble can exist only after Zyna has a durable
local record and a stable transaction id. When transport accepts, Zyna receives
the final event id directly instead of inferring it from local echo ordering.

## Render Ownership

During the outgoing lifecycle:

- Zyna owns sender-side render truth.
- Matrix owns transport truth and server truth.

That means the sender bubble is rendered from Zyna's outgoing database state
while the operation is queued, uploading, sending, retrying, or waiting for
sync. Once the final timeline event is stored and matched, the outgoing envelope
retires and normal Matrix-backed timeline rendering takes over.

This layer is not a replacement for the timeline store. It is a sender-side
stability layer above Matrix transport.

## Stored State

The common outgoing shape is an `OutgoingEnvelope` plus one or more item records.

An envelope stores:

- local identity and room identity;
- message kind;
- transport state;
- text/media payload references;
- reply snapshot;
- Zyna presentation metadata;
- stable Matrix transaction ids;
- returned Matrix event ids.

Media and non-message operations may also have dedicated durable records:

- uploaded media JSON for images, videos, files, and voice;
- protected app-owned local file paths;
- pending edit records;
- pending redaction records;
- pending reaction records;
- forwarded media source metadata.

## Outbox Runner

All outgoing outboxes share the same coordination model through
`OutgoingOutboxScanCoordinator`:

- subscribe to Matrix client state;
- scan only when the client is `.syncing`;
- coalesce repeated kicks while a scan is already running;
- optionally scope scans to a known envelope id;
- schedule retry wakeups;
- cancel work when the client leaves syncing state.

`OutgoingRetryBackoff` owns in-memory exponential retry delays, and
`OutgoingInFlightTracker` prevents parallel sends of the same logical item.

The individual `Outgoing*OutboxService` classes still own type-specific
behavior: candidate selection, payload validation, SDK call choice, upload/send
steps, event-id binding, and failure handling.

## Covered Operations

The durable direct path currently covers:

| Operation | Outbox | SDK path |
| --- | --- | --- |
| Text and replies | `OutgoingTextOutboxService` | `sendRawWithTransactionIdReturningEventId` |
| Edits | `OutgoingEditOutboxService` | raw replacement event with transaction id |
| Redactions | `OutgoingRedactionOutboxService` | `redactWithTransactionIdReturningEventId` |
| Reactions | `OutgoingReactionOutboxService` | add reaction raw event, remove by redaction |
| Images and photo groups | `OutgoingImageOutboxService` | split upload/send image helpers |
| Videos | `OutgoingVideoOutboxService` | split upload/send video helpers |
| Files | `OutgoingFileOutboxService` | split upload/send file helpers |
| Voice | `OutgoingVoiceOutboxService` | split upload/send voice helpers |
| Forwarded media | `OutgoingForwardedMediaOutboxService` | typed message resend by reference |

The old SDK timeline-send bridge, local echo transaction broker, SDK send queue
update bridge, and chat fallback sends have been removed from the chat outgoing
path.

`TimelineService` still owns timeline listening, pagination, read receipts, and
non-chat-composer Matrix operations. Call signaling is intentionally outside
this outgoing chat architecture.

Known boundary: direct reaction removal requires the reaction event id. Zyna can
reliably remove reactions it created through the direct path because that event
id is stored at add time. Older own reactions from before this architecture need
a reliable event-id mapping before they can be removed through the same durable
path.

## Retry And Restart

Retry is app-owned:

- retryable transport failures keep the durable record and move it to retrying;
- terminal failures mark the operation failed or roll back the UI state;
- app restart re-scans pending outbox records after Matrix reaches `.syncing`;
- opening the chat is not required for transport retry.

Retry uses the same transaction id, so duplicate transport attempts should
resolve to the same Matrix event instead of creating duplicate user messages.

For media, upload and event send are split. If upload succeeds and the uploaded
media JSON is saved, a later retry only resends the event. If the app crashes
after upload succeeds but before saving the uploaded JSON, retry may upload
again and leave an orphan media blob on the media repository. That is acceptable
for this architecture and is described in `MEDIA_DIRECT_SEND.md`.

## Matching And Retirement

Outgoing envelopes retire by event id. The event id returned by the direct SDK
binding is stored immediately after transport accept. When sync later stores
the same event in the local timeline database, the pending envelope can be
removed or marked sent without guessing.

Do not rely on:

- arrival order of SDK local echo;
- custom `com.zyna.*` markers returning from sync;
- message body, filename, or timestamp equality;
- in-memory waiter state.

Those are useful for diagnostics or presentation, not reliable transport
binding.

## What Not To Reintroduce

Avoid these patterns:

- waiting for SDK local echo to learn the transaction id;
- assigning SDK local events to waiters by FIFO;
- routing chat composer sends through SDK timeline send queue;
- rebuilding encrypted Matrix media JSON in Swift;
- treating filename/body equality as a stronger bind than event id;
- making retry depend on an open chat screen.

## Related Documents

- `MEDIA_DIRECT_SEND.md` explains image, video, file, voice, photo group, and
  forwarded media delivery.
- `MATRIX_SDK_DIRECT_SEND_FFI.md` records the SDK/Swift binding requirements.
- `REDACTION_FLOW.md` explains delete UI state versus persistent redaction
  delivery.
- `MEDIA_GROUPING.md` and `INCOMING_ASSEMBLY.md` explain grouped media
  presentation.
