# ADR-0004: Decouple LFS Pointers from Manifests

## Status

Accepted

## Context

The incremental sync path in `SyncEngine` derived LFS pointer paths from manifest paths via a `toPointerPath` string replacement (`manifests/` -> `binary/`, strip `.yaml`). This hard-coupled pointer discovery to manifests: a pointer could only be found if a matching manifest existed, and the two had to follow a rigid naming convention.

The full read path (`readManifestRecordsAtCommit`) already walked the `binary/` tree independently of the `manifests/` tree, but the incremental path did not, creating an asymmetry.

## Decision

1. **Independent binary tree diffing** — The generalized `listChangedPathsBetweenCommits` method diffs both the `manifests/` and `binary/` subtrees between commits. An `extensionFilter` parameter restricts manifest diffs to `.yaml` files while allowing binary paths through unfiltered.

2. **Parallel discovery** — The incremental sync orchestration diffs both trees in parallel via `Promise.all`, feeding the resulting `changedBinaryPaths` into `buildIncrementalMutationPlan` as a separate parameter alongside `changedManifestPaths`.

3. **Separated mutation loops** — `buildIncrementalMutationPlan` processes manifest changes and pointer changes in independent loops. Pointer additions and removals are determined solely by what exists in the `binary/` tree at each commit, not derived from manifest paths.

4. **`toPointerPath` deleted** — The private method and its benchmark duplicate are removed. The benchmark fixture now stores an explicit `originalPointerPath` field constructed at entry creation time.

## Consequences

- Pointers and manifests are fully decoupled in both the full and incremental sync paths.
- A pointer can appear, change, or disappear without a corresponding manifest change, and vice versa.
- The `binary/` tree diff adds a small number of extra git tree reads during incremental sync, mitigated by the existing oid-based short-circuit when trees are unchanged.
- `deriveBinaryPointerPath` in `paths.ts` remains the single source of truth for UI-side pointer path construction.
