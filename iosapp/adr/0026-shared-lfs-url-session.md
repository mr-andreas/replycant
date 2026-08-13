# ADR-0026: Shared URLSession for Git LFS

## Status

Accepted

## Context

`GitLFS` created a new `URLSession` for every batch request and every
object transfer, then called `finishTasksAndInvalidate()` as soon as the
completion handler fired. Timeline image loading runs up to six of those
transfers at once against a single `GitLFS` instance
(ADR-0019). Unsynchronized writes to a shared `uploadSession` property,
plus CFNetwork tearing down short-lived sessions on
`com.apple.CFNetwork.LoaderQ`, produced a use-after-free:
`-[__NSCFLocalSessionTask dealloc]` retained a dangling session pointer
and crashed with `EXC_BAD_ACCESS`.

`cancelActiveUpload()` also called `invalidateAndCancel()` on that shared
property, so a sync abort could cancel an in-flight image download.

## Decision

Give each `GitLFS` instance one long-lived `URLSession`:

- Build the session in `init` from a copy of the injected configuration,
  with `urlCache` disabled. LFS blobs already go through
  `ImageDiskCacheManager`; the shared URL cache raced session teardown.
- Use a dedicated `MTLSURLSessionAuthDelegate` as the session delegate.
  `GitLFS` itself is not the delegate, because `URLSession` retains its
  delegate until invalidation.
- Attach per-request behavior (`DownloadDelegate`, `UploadDelegate`,
  `StreamUploadDelegate`) via `URLSessionTask.delegate`.
- Track only in-flight upload tasks under a lock. `cancelActiveUpload()`
  cancels those tasks and never invalidates the session.
- Invalidate the session in `deinit` when the client is discarded.

## Consequences

### Positive

- Concurrent timeline downloads no longer create and destroy sessions.
- Sync cancellation cannot tear down downloads sharing the same client.
- mTLS handshake state can be reused across requests on one client.

### Negative

- A discarded client must invalidate its session; leaking a `GitLFS`
  instance now also leaks a session until process exit.
- Tests that inject `protocolClasses` still work because the
  configuration is copied, not mutated in place.

## References

- ADR-0002: Manual Git LFS Implementation
- ADR-0019: Prioritize interactive LFS image loads
- ADR-0022: Custom-Scheme Resource Loader for mTLS HLS Playback
