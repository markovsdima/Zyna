# Chat Incoming Assembly Layer

This note explains the receiver-side presentation layer Zyna uses for
grouped incoming media.

It is not a second source of truth next to Matrix. It is a thin UI
assembly layer that stabilizes how known grouped content appears while
events arrive, hydrate, or redact in separate steps.

## Why It Exists

Incoming grouped photos have a different problem from outgoing
messages.

On the receiver side, Matrix and the local database are still the
canonical truth, but that truth often arrives in phases:

- one photo may appear before the rest of the group
- raw carrier metadata may hydrate later than the first visible row
- redactions for a full group may arrive one item at a time

If UI renders directly from those intermediate states, grouped media
can briefly appear as unrelated bubbles, partial stacks, or a fast
series of per-item deletions.

The incoming assembly layer exists to smooth those phases without
owning timeline truth.

## Core Rule

For incoming grouped media:

- Matrix and the local database own truth
- the incoming assembly layer owns temporary presentation while grouped
  state is incomplete

That means:

- the underlying events are still stored and synced normally
- grouped media may render through a synthetic assembly row while the
  known set is incomplete
- once the group becomes complete, normal grouped rendering takes over

## What The Layer Does

When grouped metadata is already available locally and several
incoming image events are known to belong to the same `mediaGroup`,
but the full set is not visible yet, the assembly layer can:

- hide the constituent photo rows
- show one synthetic placeholder bubble instead
- retire that placeholder once the group is complete

This avoids obvious UI churn like:

- `1/3` photo as a standalone bubble
- then `2/3` as separate bubbles
- then a final grouped album

Instead, the receiver sees one stable placeholder until the album is
ready.

## Delete Coalescing

The same layer also helps on receiver-side deletions.

Matrix may redact a photo group as several separate child-event
redactions. Without coalescing, the UI sees a quick sequence of
individual deletions.

The incoming assembly layer can hold a short presentation window and
decide whether the receiver is seeing:

- a partial deletion, which should reflow surviving photos
- or a full group deletion, which should play one bubble-level splash
  animation

This delay is only visual. It does not delay Matrix transport or local
database writes.

## What It Is Not

This is not a mirror of the outgoing layer.

It does not:

- replace the incoming timeline model
- invent its own long-term message store
- guess groups from timing alone

It only stabilizes grouped incoming content once the local presentation
layer already knows that the events belong together.

## Relation To The Outgoing Layer

The outgoing layer and the incoming assembly layer solve related but
different problems.

- outgoing: sender-owned render truth above Matrix transport
- incoming: receiver-side presentation smoothing above Matrix-backed
  truth

They are intentionally not symmetric.

## Current Scope

This layer currently focuses on photo groups.

It is useful for:

- incomplete incoming grouped albums
- receiver-side full-group delete coalescing
- receiver-side partial delete reflow

If future grouped chat features also arrive as multi-event
constructions, they can use the same assembly pattern.
