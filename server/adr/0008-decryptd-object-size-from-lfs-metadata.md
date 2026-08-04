# ADR-0008: Resolve Encrypted Object Size From The LFS Metadata API

## Status
Accepted

## Context
`decryptd` must know the encrypted size of an object before it can map a plaintext byte range onto encrypted chunk frames. It previously discovered that size by issuing `HEAD /objects/{oid}` to upstream LFS, falling back to a `Range: bytes=0-0` probe when the response carried no `Content-Length`.

Both lookups are pathological against `git-lfs-test-server`, the object store this project deploys:

- Its content handler answers `HEAD` by running `io.Copy` over the whole file. Go discards the body for `HEAD`, but the handler still reads every byte off disk, so a `HEAD` costs a full-object read.
- It never sets `Content-Length` on `HEAD`, so the range-probe fallback always ran.
- It parses only the *start* of a `Range` header and ignores the end, so `bytes=0-0` streams the entire object.

Because `http.ServeContent` re-opens the object for every browser range request, a single video playback repeated this per request. On the reference deployment (Raspberry Pi 5, USB mechanical drive) a 1 GB video needed roughly 33 seconds before the first byte reached the player, and only became fast once the file happened to be in the page cache.

The existing test fixtures modelled a well-behaved upstream that honours range ends and reports `Content-Length` on `HEAD`, so the amplification never surfaced in CI.

## Decision
`decryptd` resolves encrypted object size through the Git LFS metadata API and caches the result.

- Size lookups issue `GET /objects/{oid}` with `Accept: application/vnd.git-lfs+json`, which the LFS metadata route answers from its metadata database without opening stored content.
- `HEAD` and the `bytes=0-0` range probe remain, but only as fallbacks for plain object stores that do not implement the LFS metadata route.
- Resolved sizes are cached per object ID. LFS object IDs are content hashes, so a size can never change for a given ID and the cache needs no invalidation.
- The up-front chunk-zero validation read requests exactly one chunk frame instead of opening a stream to end-of-object, so a client that seeks elsewhere cannot leave the object store pushing an entire media file that nobody consumes.
- Test fixtures must model `git-lfs-test-server` semantics, including the missing `Content-Length` on `HEAD` and the ignored range end.

## Consequences

### Positive
- Serving a byte range costs work proportional to the range rather than to the object, which removes the dominant source of video start-up latency.
- Repeat range requests during one playback skip upstream size resolution entirely.
- The pathological upstream behaviour is pinned by tests, so a future refactor cannot quietly reintroduce a `HEAD`-based size lookup.

### Negative
- `decryptd` now depends on the LFS metadata route rather than generic HTTP semantics, narrowing the set of object stores it works well with. The fallbacks preserve correctness but not performance.
- The size cache keeps a bounded amount of state in a service that was previously stateless.
