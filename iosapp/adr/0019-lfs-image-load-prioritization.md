# ADR-0019: Prioritize interactive LFS image loads

## Status

Accepted

## Context

Timeline thumbnails and fullscreen originals both fetch bytes through
`ImageDiskCacheManager`, which falls back to `Repository.loadLFSData`
after disk-cache misses.

When users scroll quickly or when warmup runs after sync, many LFS fetches
can overlap. Without shared scheduling, high-value interactive requests
(viewport and fullscreen) compete equally with lower-value background work
(page preload and warmup), increasing visible latency.

## Decision

Introduce a centralized LFS request scheduler for image loading:

- Add `LFSRequestScheduler` as an actor that:
  - enforces a fixed max-concurrency budget for LFS fetches
  - serves queued requests by priority
  - preserves FIFO order for requests with equal priority
  - de-duplicates concurrent requests with the same cache key
- Use the scheduler only for LFS network/decrypt work. Disk-cache hits
  still return immediately and bypass queueing.
- Define image-load priorities from highest to lowest:
  - `fullscreenCurrent`
  - `fullscreenNeighbor`
  - `timelineViewport`
  - `timelinePage`
  - `topWarm`
  - `mainWarm`
- Thread priority tags from all call sites into
  `ImageDiskCacheManager.loadImageData`, `warmTop`, and `warmMain`.

The scheduler does not preempt already-running downloads. Priority applies
to queue order for the next available slot.

## Consequences

### Positive

- Fullscreen current image requests are no longer queued behind warmup work.
- Fullscreen neighbor and viewport requests are consistently favored over
  page preload and cache warming.
- Duplicate in-flight fetches for the same key collapse into one network
  operation, reducing bandwidth and redundant decrypt work.
- Concurrency is bounded, reducing network bursts and contention.

### Negative

- Adds central scheduling complexity in a hot path.
- Priority only affects queued work; an already-running low-priority fetch
  still consumes a slot until completion.
- Mis-tagged call sites could unintentionally starve lower priorities.
