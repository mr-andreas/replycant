# 0002 — Streamed Rehydration Pipeline

**Status:** Superseded by [ADR 0008](0008-firefox-safe-chunked-rehydration.md)

The single long-lived transaction in Stage C broke on Firefox because the
IndexedDB specification requires that a transaction auto-commits as soon as
control returns to the event loop with no pending IDB requests, and Stage C
awaits non-IDB promises (channel handoffs) between writes. ADR 0008 replaces the
single transaction with chunked transactions and a staged commit marker while
preserving the streaming pipeline shape described below.

## Context

During full rehydration the webapp reads all manifest YAML blobs from the git object store, decodes them into `RegisteredManifestRecord` objects, accumulates the entire set in memory, and only then writes the complete snapshot to IndexedDB via `replaceCache`. For large libraries (160k+ manifests) this creates two problems:

1. **High peak memory** — the full decoded record set lives in the JS heap for the entire duration of reading plus writing.
2. **Sequential bottleneck** — IDB writes cannot begin until every blob has been read and decoded, leaving the database idle while the CPU-bound decode phase runs and vice versa.

## Decision

Replace the batch read-all-then-write pattern with a three-stage streaming pipeline connected by bounded async channels:

- **Stage A (Git Read):** Reads raw blobs from isomorphic-git in batches and pushes `{ oid, path, blob }` items into a bounded channel.
- **Stage B (Decode):** Receives raw blobs, decrypts/decodes YAML, resolves primary keys, and pushes `RegisteredManifestRecord` items into a second bounded channel.
- **Stage C (IDB Write):** Receives decoded records and writes them into IndexedDB within a single `readwrite` transaction opened by `replaceCacheStreamed`.

A lightweight `BoundedChannel<T>` class (capacity-limited, backpressure-aware, Promise-based) connects the stages. All three stages run concurrently via `Promise.all`.

LFS pointer blobs are few and fast, so they are read and written in a small post-pipeline step using a dedicated `writePointers` method.

## Consequences

**Positive:**
- Peak memory drops because records flow through the pipeline and are released to GC after the IDB `put`, instead of accumulating in a single array.
- Reading, decoding, and writing overlap in time, reducing total wall-clock duration.
- The bounded channel capacity (200 items per channel) bounds in-flight memory regardless of library size.

**Negative:**
- IDB transaction liveness requires that Stage C never starves for long enough that the browser auto-commits the transaction. In practice, Stage B (CPU-bound YAML decode) is faster than Stage A (git I/O), so channel B stays populated.
- The atomicity model changes subtly: the old `replaceCache` held all records before opening the transaction, while the streamed variant opens the transaction first and feeds it incrementally. If the pipeline errors mid-stream the transaction is aborted, preserving the previous cache state.
- Pointers are now written in a separate transaction after the main pipeline, introducing a brief window where manifests are committed but pointers are not yet visible.
