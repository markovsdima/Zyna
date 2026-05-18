# Matrix SDK Direct Send FFI

This document records the Matrix Rust SDK Swift binding requirements that make
Zyna's durable outgoing architecture possible.

## Required Property

Every chat outgoing SDK helper used by Zyna must support:

- caller-provided Matrix transaction id;
- direct transport without SDK timeline local echo binding;
- returned Matrix event id after server accept;
- SDK-owned encryption and typed event construction where applicable.

The returned event id is the durable bind point. Transaction id idempotency makes
retry safe. Local echo ordering is not part of the contract.

## Current Bindings

Text-like events:

```swift
Room.sendRawWithTransactionIdReturningEventId(
    eventType: String,
    content: String,
    transactionId: String
) async throws -> String
```

Redactions:

```swift
Room.redactWithTransactionIdReturningEventId(
    eventId: String,
    reason: String?,
    transactionId: String
) async throws -> String
```

Media upload/send:

```swift
Room.uploadImageForEvent(...) async throws -> String
Room.sendUploadedImageWithTransactionIdReturningEventId(...) async throws -> String

Room.uploadVideoForEvent(...) async throws -> String
Room.sendUploadedVideoWithTransactionIdReturningEventId(...) async throws -> String

Room.uploadFileForEvent(...) async throws -> String
Room.sendUploadedFileWithTransactionIdReturningEventId(...) async throws -> String

Room.uploadVoiceForEvent(...) async throws -> String
Room.sendUploadedVoiceWithTransactionIdReturningEventId(...) async throws -> String
```

Forwarded media:

```swift
Room.sendMessageTypeWithTransactionIdReturningEventId(
    msgtype: MessageType,
    transactionId: String,
    replyEventId: String?
) async throws -> String
```

Exact Swift signatures may change with generated UniFFI naming, but these
capabilities are the contract Zyna depends on.

## Why Typed SDK Helpers Matter

Use typed SDK/Ruma helpers for operations with Matrix-specific event shape:

- media messages;
- voice messages;
- replies and mentions when SDK can build them safely;
- redactions.

Do not rebuild encrypted media JSON in Swift. It is easy to get E2EE media
wrong: encrypted media uses `file`, encrypted thumbnails use `thumbnail_file`,
media encryption metadata must match the upload, and mimetype/thumbnail/caption
fields need Matrix-compatible shapes.

For redactions, use the room redaction API, not raw message send. Room versions
and homeserver behavior can affect the redaction event shape.

## Adding A New Outgoing Operation

The expected pattern is:

1. Add or expose a Room-level SDK helper that accepts a caller transaction id.
2. Make the helper return the accepted event id.
3. Keep SDK/Ruma responsible for typed Matrix event construction.
4. Add a Zyna durable pending record before transport.
5. Store the transaction id on the pending record before transport.
6. Send through an `Outgoing*OutboxService`.
7. Store the returned event id and let sync retire the outgoing envelope.

If upload is involved, prefer split upload/send:

- upload returns opaque persisted SDK JSON;
- Zyna saves that JSON;
- send consumes the JSON with the same transaction id and returns event id.

## Do Not Depend On

Avoid these as correctness mechanisms:

- SDK timeline local echo;
- SDK send queue updates;
- FIFO waiter-to-transaction-id assignment;
- custom `com.zyna.*` event markers returning from sync;
- filename/body/timestamp equality.

They can be useful for diagnostics or presentation, but not for durable binding.

## Fork Maintenance

When the SDK fork gains a new binding:

1. Validate it in the SDK repository with at least `cargo check -p
   matrix-sdk-ffi` and `cargo test -p matrix-sdk-ffi --lib`.
2. Build/generated Swift bindings as needed by the SDK release flow.
3. Publish or tag the package revision used by Zyna.
4. Bump `MatrixRustSDK` in Zyna separately from the Zyna integration code when
   practical.
5. In Zyna, first prove the thin SDK call, then wire the durable outbox path.
