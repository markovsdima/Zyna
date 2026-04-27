# Chat Redaction Flow

This note describes the current delete and redaction model for chat
messages. The goal is immediate UI feedback with reliable redaction
delivery across app restarts and chat reopen.

## Core Model

Delete now has two separate layers:

- local UI hiding and partial media reflow
- persistent redaction delivery and retry

These layers must stay separate.

The delete path is:

`ChatView -> ChatViewModel -> PendingRedactionService -> TimelineService -> Matrix -> GRDB -> MessageWindow -> ChatViewModel`

## Responsibilities

`ChatView` owns:

- delete gestures
- paint splash animation
- pending animated delete targets

`ChatViewModel` owns:

- local hidden display state
- partial media-group reflow
- temporary pre-redaction content used during delete animation

`PendingRedactionService` owns:

- persistent redaction intents
- retryable vs terminal failure classification
- retry on next live timeline start
- reconciliation when GRDB materializes `contentType = 'redacted'`

`TimelineService` owns:

- the actual `redactEvent(...)` call into Matrix timeline

## Persistent Intent

Persistent delete state is keyed by:

- `messageId` for local UI identity
- `roomId` for room scoping
- `eventId` or `transactionId` for delivery

`messageId` alone is not enough for reliable retry. Delivery needs the
Matrix item identifier.

If a message still only has a `transactionId` when delete starts,
`PendingRedactionService` can upgrade that intent to `eventId` later by
re-reading `storedMessage`.

## Lifecycle

When the user deletes a message:

1. `ChatView` captures any animation target it needs.
2. `ChatViewModel` keeps enough local state to hide the message
   immediately and preserve media-group reflow.
3. `PendingRedactionService` persists a redaction intent.
4. `TimelineService` attempts `redactEvent(...)`.

If the redaction echo arrives normally:

- GRDB materializes `contentType = 'redacted'`
- `PendingRedactionService` clears the persistent intent
- `ChatViewModel` stops filtering the message through pending state

If the app is killed before that happens:

- the pending intent remains in GRDB
- the message stays hidden on reopen
- retry happens after the room timeline is listening again

If delete fails with a terminal error:

- the persistent intent is cleared immediately
- local hidden state is rolled back
- the message becomes visible again

If delete fails with a retryable error:

- the persistent intent remains stored
- the message may stay hidden locally
- retry happens on the next timeline start

## UI State vs Delivery State

These are different things:

- `pendingPartialRedactions`
- `hiddenIds`
- `pendingRedaction`

`pendingPartialRedactions` is visual reflow state.

`hiddenIds` is session-local display state.

`pendingRedaction` is persistent delivery state.

Do not collapse these into one mechanism.

## Invariants

If this model is working correctly:

- delete hides immediately
- reopen does not reintroduce a locally deleted message
- unresolved deletes survive app restart
- retry does not depend on `ChatViewModel` staying alive
- delivery can continue after `transactionId -> eventId` transition
- media-group reflow stays a UI concern, not a persistence concern
- terminal failures do not leave messages hidden locally forever

## Do Not Reintroduce

Avoid these patterns:

- storing reliable delete retry only inside `ChatViewModel`
- using `messageId` alone as the delivery identifier
- making media reflow state responsible for persistent retry
- clearing pending delete state before GRDB sees `redacted`
