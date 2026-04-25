# Chat Outgoing Layer

This note explains the sender-side message layer we added on top of
Matrix transport.

It is not a cosmetic refactor. It is a deliberate architectural layer
that keeps outgoing UI stable while the SDK goes through noisy local
echo, upload, replace, sync, and hydration stages.

## Why It Exists

Matrix local echo is useful, but it is not a reliable UI truth for
Zyna.

That is especially true when:

- the SDK emits temporary local echo states
- raw event JSON arrives later than the first visible message row
- Zyna-only metadata lives in hidden spans, not in the typed SDK model
- one visual message is really a richer Zyna concept, like a grouped
  photo bubble

If sender UI renders directly from those transient SDK rows, bubbles
can jump, split, collapse, duplicate, or lose custom presentation
rules.

The outgoing layer exists to stop that.

## Core Rule

For outgoing messages:

- Zyna owns render truth
- Matrix owns transport truth and server truth

That means:

- the sender bubble is rendered from Zyna's local outgoing state
- Matrix send queue is used for `transactionId`, upload progress,
  retries, `eventId`, and final server-backed content
- incomplete or missing SDK metadata must not overwrite already known
  local truth

## What The Layer Contains

The layer is represented by `OutgoingEnvelope` records and item
records in the local database.

Each envelope stores:

- local identity
- room identity
- kind
- current transport state
- payload
- reply snapshot
- Zyna metadata
- item-level transport bindings like `bindingToken`, `transactionId`,
  `eventId`, and uploaded media source

This makes the outgoing state persistent across:

- leaving and re-entering the chat
- delayed sync
- late raw JSON hydration
- long uploads
- retries and failures

## Why We Still Split By Kind

The lifecycle is shared, but payload and matching rules are not.

We currently keep separate kinds for:

- `text`
- `image`
- `voice`
- `file`
- `mediaBatch`

This is intentional.

The state machine is common, but these message types differ in:

- synthetic rendering
- transport payload
- how they match and retire against timeline messages
- what data they need before they can be considered hydrated

Without kinds, the layer would turn into one weak optional-field blob
and become less reliable, not more universal.

## Binding Model

The layer does not depend on "did send return a transaction id right
away".

Each outgoing item is created with a persistent `bindingToken`.

The transport flow then resolves:

`bindingToken -> transactionId -> eventId / media source`

This removes the fragile gap where a sender bubble could exist before
it had a stable binding to the Matrix send queue.

## Render Ownership

The outgoing layer is only for sender-side rendering during the
outgoing lifecycle.

It is not a replacement for the normal timeline model.

The rule is:

- while the message is still in outgoing lifecycle, UI may render from
  the envelope
- once the final timeline message is stable and matched, the envelope
  retires
- after that, normal persisted timeline state takes over

So this is not "our own chat protocol". It is a sender-side stability
layer above Matrix transport.

## Why It Matters For Zyna

Zyna keeps adding features that do not map cleanly to the SDK's early
typed local echo model.

Examples:

- grouped photo bubbles
- caption placement rules
- forwarding metadata
- future custom Zyna tags and presentation rules

The outgoing layer lets us support those features without making UI
shape depend on when the SDK decides to expose raw carrier metadata.

## Current Scope

This layer is for outgoing messages.

It is not used as the source of truth for:

- incoming messages
- read receipts
- reactions
- long-term timeline ownership

Those stay in the normal Matrix-backed message pipeline.

## Practical Goal

The sender should see the message in its final intended shape
immediately, and it should stay visually stable while Matrix transport
does its work underneath.

That is the entire point of this layer.
