# 0008 — Firefox-Safe Chunked Rehydration

**Status:** Accepted (supersedes ADR 0002)

## Context

ADR 0002 introduced a three-stage streaming pipeline for full rehydration where
Stage C (`ManifestDatabase.replaceCacheStreamed`) consumed decoded records from a
`BoundedChannel` and wrote them into IndexedDB within a single long-lived
`readwrite` transaction. It noted as a risk that "IDB transaction liveness requires
that Stage C never starves for long enough that the browser auto-commits the
transaction" and assumed Stage A (git I/O) would keep the channel populated.

In production this assumption failed on Firefox. With 63k+ manifest blobs the git
read stage starves the channel frequently, and even when the channel is non-empty
the consumer awaits a `new Promise(...)` resolved by `BoundedChannel.receive()` —
which is a non-IDB promise. Per the IndexedDB specification, a transaction's
`active` flag is set back to `true` only while one of its request callbacks runs;
when control returns to the event loop with no pending IDB requests, the
transaction commits. Firefox implements this strictly. Chromium has historically
been lenient and keeps transactions alive across microtask waits even when no
request is pending, which is why the same code path succeeded in Chrome.

The observable symptom in Firefox is `TransactionInactiveError` thrown from the
next `tx.objectStore(...).put(record)` after the dead transaction, surfaced to the
user as `"Sync failed: A request was placed against a transaction which is
currently not active, or which is finished."`

The incremental sync path (`ManifestDatabase.applyIncrementalWithCas`) does not
suffer this defect because its mutation is fully materialized in memory before the
transaction opens and every `await` inside the transaction is on an IDB request.
Firefox keeps transactions alive across IDB request callbacks, so the single
transaction model is correct there.

## Decision

Use two distinct implementations for cache writes, with intentionally different
transaction strategies driven by their intrinsically different correctness
requirements.

### Incremental updates: one CAS-guarded transaction

`applyIncrementalWithCas` remains a single `readwrite` transaction spanning
manifest stores, the pointer store, derived stores, and the meta store. The CAS
guard (`expectedSyncedCommitHash`) means an incremental update races against
concurrent sync attempts to advance from the same base commit; either it wins and
commits atomically or it loses and aborts cleanly. The mutation arrives fully
materialized as a `ManifestDatabaseMutation`, so the implementation only ever
awaits IDB requests. This is Firefox-safe by construction.

### Full rehydration: chunked transactions with a staged commit marker

`replaceCacheStreamed` is split into four short phases, each its own transaction:

1. **Begin** — write `syncState=in_progress`, `stagedCommitHash=newHash` and
   `clear()` every manifest store and the pointer store.
2. **Chunk loop** — accumulate streamed records into an in-memory buffer of
   `FULL_REHYDRATION_CHUNK_SIZE` (default 2000). When the buffer fills or the
   stream ends, open a fresh transaction, enqueue all `put`s synchronously
   (no `await` between them), and `await tx.done`. Between chunks the code is
   free to await anything (the channel, the next git read, decode) because no
   transaction is open.
3. **Pointers** — if pointers are supplied, write them in one short transaction.
4. **Commit** — clear and rebuild derived stores, then flip the commit marker:
   `syncState=idle`, `syncedCommitHash=newHash`, `stagedCommitHash=null`. Derived
   rebuild runs here so it observes the complete final snapshot rather than a
   partial mid-stream view.

Consumer-visible atomicity is preserved by the existing meta-state machine:
readers gate on `syncedCommitHash`, which only advances in the final commit
transaction. While a full rehydration is in flight the cache may legitimately
contain a partial set of records, but the `syncedCommitHash` still reflects the
previous (or null) snapshot, so consumers never render the partial state.

### Recovery model

If any phase fails — including an exception thrown mid-stream by the producer —
the failure propagates up, no commit-marker advance has occurred, and the next
boot finds `syncState=in_progress`. The existing `recoverInterruptedCacheUpdate`
clears the in-progress marker, and the next full rehydration's begin phase wipes
any partial chunk writes from the previous attempt. There is no torn-snapshot
window from the consumer's perspective.

### Derived-hook contract

Derived store `rebuild` and `applyMutation` hooks may only await IDB requests.
Awaiting any non-IDB promise (fetch, setTimeout, channel handoff, decryption)
will drop the surrounding transaction in Firefox. This contract is documented on
`DerivedStoreDefinition` and applies symmetrically to the rebuild during full
rehydration commit and the mutation hook during incremental apply.

## Consequences

**Positive:**
- Full rehydration completes reliably in Firefox at production scale (60k+
  manifests) without sacrificing the streaming memory bound.
- Peak memory cost is bounded by chunk size (default 2000 records) instead of
  total record count, matching the original ADR 0002 goal.
- The two implementations now have crisp, documented correctness contracts
  matched to their actual concurrency requirements: incremental is atomic against
  concurrent writers; rehydration is atomic at the commit marker only.
- The chunked design works equally well on Chromium-based runtimes (Electron,
  Chrome, Edge) — there is no browser-specific code path.

**Negative:**
- More transaction overhead than the single-transaction design, though
  amortized across `FULL_REHYDRATION_CHUNK_SIZE` records per transaction.
- A failed rehydration may leave partial chunk writes in object stores until the
  next rehydration's begin phase clears them. This is benign because readers
  never see records that postdate `syncedCommitHash`, but storage usage may
  briefly include orphaned rows between an interruption and the next sync.
- The derived-hook contract becomes load-bearing: a regression that awaits a
  non-IDB promise from a derived hook would re-introduce Firefox failures. The
  contract is documented on the interface and called out in code comments.
