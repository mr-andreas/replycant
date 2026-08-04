# ADR-0025: Drop Chunk-Size Header from Decryptd Playback

## Status

Accepted (supersedes ADR-0013's requirement to send `X-Replycant-Chunk-Size`)

## Context

ADR-0013 required iOS fullscreen playback to forward both `X-Replycant-DEK` and
`X-Replycant-Chunk-Size` to `transcoded` / `decryptd`. ADR-0024 pins chunk size
to a repo-wide compile-time constant, so the header is no longer meaningful
geometry and remains attacker-malleable if kept on the wire.

## Decision

Playback and proxy paths send only `X-Replycant-DEK` (and the webapp equivalent
`?dek=` query parameter). Chunk size is never read from:

- LFS pointer field `x-replycant-chunk-size`
- HTTP header `X-Replycant-Chunk-Size`
- Query parameter `chunkSize`

`decryptd`, `transcoded`, `gitd` CORS, the webapp Node proxy, and iOS resource
loaders are updated accordingly. ADR-0013's DEK-forwarding decision otherwise
remains in effect: KEK stays on-device; only the request-scoped DEK is forwarded.

## Consequences

### Positive

- Removes a malleable header from the media path.
- Simplifies clients and CORS allow-lists.

### Negative

- Version skew between client and `decryptd` constants fails as GCM auth errors.

## References

- ADR-0013: Decryptd Playback with DEK Forwarding
- ADR-0024: Authenticated Chunk Framing for Encrypted LFS Objects
