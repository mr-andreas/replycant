# ADR-0018: Consolidate Thumbnail manifests into ThumbnailSet

## Status

Accepted

## Supersedes

ADR-0005 Thumbnail Storage Architecture

## Context

The previous thumbnail protocol stored one `Thumbnail` manifest per resolution. With three generated resolutions per original (`150x150`, `225x225`, `1024`), each original produced three thumbnail manifests.

At repository scale this multiplied manifest counts, increased sync parse work, and inflated manifest tree churn for updates that belong to a single original.

## Decision

Replace per-resolution `Thumbnail` manifests with one `ThumbnailSet` manifest per original.

- New manifest kind: `ThumbnailSet`
- `ThumbnailSet.spec` contains:
  - `originalRef`
  - `thumbnails[]` entries (`name`, `sha256`, `width`, `height`, `filesize`)
- Keep one binary pointer per derived thumbnail file.
- Store binary pointers at:
  - `binary/{deviceSpace}/media.replycant.com/v1alpha1/ThumbnailSet/{entry.name}`
- Store one manifest at:
  - `manifests/{deviceSpace}/media.replycant.com/v1alpha1/ThumbnailSet/{set-name}.yaml`

This creates a 1:N relationship:

- 1 `ThumbnailSet` manifest
- N thumbnail binary pointers (one per entry)

## Consequences

### Positive

- Reduces manifest-file count for thumbnails by roughly 3x for default generation.
- Decreases manifest traversal/parsing overhead during sync.
- Makes thumbnail variants for one original update atomically in one manifest document.
- Keeps runtime render model unchanged (`NormalizedThumbnail` rows remain per variant).

### Negative

- Protocol and storage semantics become 1:N for thumbnails, while `Original` stays 1:1.
- Commit and sync code must support explicit per-entry binary pointer resolution.
- Existing docs/tests/fixtures referencing `Thumbnail` must be updated to `ThumbnailSet`.
