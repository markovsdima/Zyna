# Matrix SDK Event Inspection FFI

Status: implemented in Zyna and available in the linked `26.5.13-zyna.5-beta.15` package.
The Swift integration tests exercise the actual XCFramework and UniFFI.

## Confirmed problem

Zyna persists its chat projection independently of the SDK timeline window.
An encrypted event can initially become a decryption placeholder. After
decryption, it can turn out to be an edit, reaction, poll response/end, or
another event that the SDK does not render separately. The SDK removes that
item, but positional removals also occur during window changes, so Zyna
cannot interpret every removal as permission to delete retained history.

## API contract

Linked Swift contract:

```swift
enum RoomTimelineEventDisposition {
    case visible
    case hidden
    case unableToDecrypt
    case indeterminate
}

struct RoomTimelineEventInspection {
    let event: RawRoomEvent
    let disposition: RoomTimelineEventDisposition
    let decryptionFailure: EncryptedMessage?
}

extension Room {
    func inspectTimelineEvent(eventId: String) async throws
        -> RoomTimelineEventInspection
}
```

The API uses the existing `RawRoomEvent` and `EncryptedMessage` types and
preserves the complete decrypted event JSON, including
`m.relates_to`, `m.new_content`, `unsigned`, and original event identity.
This data is for processing inside the encrypted account store, not logging.

`EncryptedMessage` with its existing `UtdCause` is sufficient for this API.
No new low-level crypto error payload is required. A known decryption failure
with cause `Unknown` remains `unableToDecrypt`; it is not evidence for
`hidden`. `decryptionFailure` is non-nil for `unableToDecrypt` and nil for
the other dispositions.

The method must work without constructing or retaining a UI timeline,
without changing any existing timeline's focus, and without pagination.
A one-event API is sufficient: Zyna owns the bounded, cancellable queue.

## Resolution semantics

1. Validate the requested ID and resolve it inside this `Room`, using the
   event cache first and the homeserver when necessary. Validate the
   returned event identity. Lookup, network, and authorization failures
   throw; none implies a hidden or deleted event.
2. If a cached event is still encrypted, retry decryption with the current
   SDK crypto state. The existing `load_or_fetch_event` returns a cached
   entry immediately, so calling it alone is insufficient when keys arrived
   after that entry was stored. Use the normal room decryption path, with
   the client's trust settings and ordinary SDK key-recovery behavior.
3. Inspect the SDK's `TimelineEventKind` before converting to the existing
   FFI `TimelineEvent`, which loses decryption metadata. An actual UTD must
   return `unableToDecrypt` with its typed reason, including trust failures.
   A still-encrypted envelope is never evidence for `hidden`.
4. Classify a successfully parsed, decrypted or originally plaintext event
   with the SDK's default main-timeline policy and this room's version
   rules. Use `matrix_sdk_ui::timeline::default_event_filter` rather than
   maintaining a second list of aggregation rules in Swift. Include thread
   replies: being outside a particular UI window or thread is not a reason
   for `hidden`.
5. Return `hidden` only for a recognized event that the default SDK policy
   excludes as a standalone item. This includes message/poll replacements,
   reactions, poll responses/ends, redaction events with a target, and other
   recognized signaling events. Preserve relation metadata in `event`.
6. Unknown/custom event types, unsupported custom message types, malformed
   content, or insufficient classification data are `indeterminate` (or a
   typed error when an inspection record cannot be built), never `hidden`.
   Redacted events follow SDK room-version rules; do not infer a hidden
   relation merely from their empty content or missing original body.

The returned event is the requested event, not its replacement target,
latest edit, or thread root. `visible` means eligible under the SDK policy;
it is not a complete, aggregated `EventTimelineItem` and does not promise
that the item is currently present in a live timeline.

Inspection does not write its results to the SDK event cache.
It reads the cached event, or fetches the raw event through the authenticated
SDK client, and decrypts/classifies a local copy. `Room.event` saves its result
to the event cache, and `load_or_fetch_event` uses that path on a cache miss;
wrapping either method alone does not satisfy this requirement. In particular,
inspection must not overwrite a newer decrypted copy installed concurrently
by sync or normal key recovery.

Ordinary SDK crypto/key-recovery side effects remain allowed. Cancellation
uses normal UniFFI async cancellation and ends the inspection call and its
owned work. It need not stop shared/background key recovery already started
by the SDK. This method sends no chat messages, redactions, read receipts,
or typing events. Zyna must still reject late results after cancellation or
account retirement, independently of background SDK recovery.

## Why existing APIs are insufficient

- `Timeline.getEventTimelineItemByEventId` only searches the current window.
- `Room.loadOrFetchEvent().content()` drops message/poll edit relations and
  rejects poll response/end types. Production and diagnostics now use the
  typed inspection API instead of matching error strings.
- `subscribeToRawTimelineEvents` uses live event handlers; it is not a
  contract for replaying cached history and later decryption results.
- Creating one event-focused timeline per candidate invokes `/context`,
  starts timeline tasks, and adds an `EventFocusedCache` to the room's
  retained map. It is unsuitable for repairing a large account cache.
- `roomEventsDebugString` is diagnostic output, not a stable data interface.

## Regression coverage requirements

- Ordinary text, media, poll starts, replies, and thread replies are visible.
- Message edits, poll edits, reactions, poll responses, poll ends, and known
  hidden signaling events are hidden, with the original event ID retained.
- A reaction/response whose target is absent from the cache is still
  classified from its own content, without creating a target placeholder.
- A cached encrypted event first returns UTD; after importing keys, a new
  inspection returns its real type and disposition without reopening the
  room or creating a timeline. Cover a normal message and an edit/reaction.
- Trust failures, unavailable keys, malformed events, unknown custom types,
  404, forbidden access, and network errors never yield hidden.
- Redacted ordinary events and redacted relations follow the default SDK
  policy. Exercise the relevant room-version redaction rules.
- Inspection leaves the live timeline focus and event-focused cache count
  unchanged and performs no event-cache writes, on cache hits or misses.
  Include a race where sync installs a decrypted copy during inspection.
- `UtdCause.Unknown` remains UTD, with a non-nil typed failure; other
  dispositions carry no decryption failure.
- Cancellation terminates the inspection call and its owned work; already
  started SDK background key recovery may continue. Do not require stopping
  recovery shared with other consumers.
- Swift bindings and the XCFramework must match the package version/checksum;
  verify the linked binary through Swift integration tests.

## Zyna integration

The account-bound repair worker consumes this contract. It stores typed UTDs,
uses legacy labels only to select candidates, and applies results only while
the stored identity, generation and inspected row still match. Confirmed hidden
identities have durable suppression against late UTD replays.

Zyna's `ChatEventVisibility` also excludes proven app service events, including
the custom `io.element.call.reaction` type that Ruma classifies as indeterminate.
This is an app policy, not a change to the SDK disposition contract.

See [Retained Decryption Repair](SCROLL_AND_PAGINATION.md#retained-decryption-repair)
for exclusions, queue scheduling, stale-result checks, suppression, admission
and UI refresh rules. Visible raw events never substitute for the SDK's complete
aggregated projection; remaining unknowns and failures are retained for retry.

The reconciliation store and admission gate use the linked inspection API.
Integration tests exercise the real SDK dispositions and mapped timelines;
window tests cover delayed hydration, restart migration and hidden pages.
