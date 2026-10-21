# ADR-0033: Off-main-thread upload pipeline

## Status

Accepted

## Context

Photo upload runs from `PhotoSyncManager`, which publishes progress on the
main actor. The sync task is created there, so the per-photo work inherited
that isolation: hashing the original, encrypting thumbnails, reading the
database version, and writing the git commit.

The commit rewrites the whole index. On a large library that stalls the main
thread long enough for a zoomed photo to hitch while panning. A refresh of
the timeline count on every commit adds another main-actor query per photo.

## Decision

Hashing, thumbnail encryption, the database-version read, and the libgit2
commit run on a detached task at utility priority. `PhotoSyncManager` stays
on the main actor and only publishes sync state.

One `KEKEpochManager` is kept for the life of a commit service, so later
photos reuse the decrypted key.

Timeline database notifications coalesce on a 300 ms trailing window. A burst
of commits refreshes the count and month index once. A full replace discards
any incremental edits buffered in that window.

## Consequences

### Positive

- Panning a zoomed photo and scrolling the timeline stay responsive while
  photos upload.
- The main actor is no longer blocked for the length of an index rewrite
  that grows with the library.

### Negative

- Upload preparation can be preempted by UI work, so a sync that runs beside
  active scrolling takes longer.
- A timeline refresh waits until a burst of commits has been quiet for
  300 ms, so a new photo can appear slightly later.
