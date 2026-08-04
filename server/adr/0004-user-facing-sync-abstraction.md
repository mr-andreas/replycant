# ADR-0004: User-Facing Sync Abstraction

## Status
Accepted

## Context
Replycant stores media metadata in Git and uses sync logic that compares repository revisions internally. Exposing internal diff concepts (for example, object-level change highlights or commit-hash details) in the main timeline UI makes users reason about synchronization mechanics instead of their photo library. This increases perceived instability during normal sync updates and conflicts with the product goal of seamless background synchronization.

## Decision
The webapp treats Git as an implementation detail and presents synchronization as a transparent data-service experience.

- Timeline UI must not surface developer-facing diff visualizations such as object-level border highlights.
- Primary sync messaging remains user-oriented: syncing state, last successful sync, and actionable recovery only when needed.
- Internal change detection, commit-hash tracking, and conflict classification remain in code for correctness, recovery, and diagnostics, but are not shown by default in core browsing views.

## Consequences
### Positive
- Users focus on their media library instead of transport or storage internals.
- Normal sync updates feel stable and predictable, reducing UI flicker perception.
- Internal safety mechanisms remain available without leaking technical complexity.

### Negative
- Developers lose an always-visible in-UI signal for object-level changes.
- Deep sync diagnostics may require logs or dedicated developer tooling.
