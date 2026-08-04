# ADR-0016: Enforce HEAD Mutation Through GitDB Package

## Status

Accepted

## Context

The iOS app split git HEAD mutations and SQL cache synchronization across call sites. Several paths performed `createCommit` or `pullRebase` separately from `syncToHead`/`syncAfterCommit`. This made cache consistency depend on each caller remembering to chain APIs correctly.

We observed stale timeline behavior caused by this separation and by sync code paths that could advance synced metadata without rebuilding rows.

## Decision

Introduce a dedicated local Swift package named `GitDB` and require that HEAD-mutating flows route through it.

- `GitDB.commitFiles(...)` performs git commit and SQL sync as one operation.
- `GitDB.pull(...)` performs pull/rebase and SQL sync as one operation.
- `GitDB.syncToHead(...)` remains available for idempotent convergence paths.
- App call sites that mutate HEAD must use `GitDB` instead of direct `Repository.createCommit` / `Repository.pullRebase`.
- Sync fallback is hardened so `HEAD != syncedCommitHash` with empty changed paths performs full hydration rather than only advancing metadata.

## Consequences

### Positive

- HEAD mutation and SQL sync become a single enforced boundary.
- Callers become simpler and less error-prone.
- Timeline readers get more reliable convergence after pull/commit operations.

### Negative

- Adds package boundary complexity and duplicate type management during migration.
- Requires app target wiring to consume a new local package.
