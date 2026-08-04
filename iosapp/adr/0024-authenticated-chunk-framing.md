# ADR-0024: Authenticated Chunk Framing for Encrypted LFS Objects

## Status

Accepted

## Context

ADR-0012 described index-derived nonces for chunked LFS encryption, but decryptors
across Go, Swift, and TypeScript read the nonce from the wire with empty AAD.
GCM therefore authenticated each frame in isolation, not its position: an attacker
who can reorder or drop trailing chunks produced ciphertext that still decrypted.

Chunk size was also attacker-supplied geometry (`x-replycant-chunk-size` on
pointers and `X-Replycant-Chunk-Size` on media requests), even though no client
chose a per-object value. iOS used 1 MiB; Go and the Kiliaro importer used 4 MiB.

## Decision

Adopt v2 chunk framing across Go, Swift, TypeScript, and `decryptd`:

1. **Fixed chunk size**: 64 KiB (65536) plaintext bytes, compile-time constant on
   every platform. Absent from pointers, headers, and query parameters.
2. **Derived nonce**: 12 bytes `0x00000000 || uint64BE(index)`, never stored.
3. **AAD**: `"replycant-lfs-chunk-v1" || uint64BE(index) || uint8(isLast)`.
4. **Wire frame**: `ciphertext || tag` only (16-byte overhead per chunk).
5. **DEK wrap AAD**: `"replycant-dek-wrap-v1" || uint64BE(kekEpoch)` so wrapped
   DEKs cannot move across epochs.

Empty plaintext produces zero chunks. Random access is preserved: seeking to
chunk `i` is still `read(i * (ChunkSize + 16), …)` plus one `Open`.

### Why 64 KiB

Measured after a Chromium/Firefox decrypt sweep and a transcode-like seek model
against an 80 MiB moov-at-end video:

- Browser decrypt throughput at 64 KiB stayed within ~10% of the 1 MiB baseline
  for photo-sized payloads (Firefox thumbnails regress in call count only, at
  sub-millisecond absolute cost).
- Seek waste on `decryptd` range opens is dominated by network: one HLS-like
  session needed +1% upstream bytes at 64 KiB versus +27% at 1 MiB and +153%
  at 4 MiB.

## Consequences

### Positive

- Reorder and trailing truncation fail authentication.
- Clients and `decryptd` share one geometry; pointer/header skew disappears.
- Smaller seek waste for video probing and segment starts.

### Negative

- Breaking change: every existing encrypted LFS object becomes unreadable and
  all LFS OIDs change. Acceptable under alpha rules; no migration.
- If a client and `decryptd` are ever built with different constants, failures
  surface as opaque GCM authentication errors rather than a clean 400.

## References

- ADR-0012: KEK/DEK Envelope Encryption with age Key Wrapping
- ADR-0025: Drop Chunk-Size Header from Decryptd Playback
- SecurityAudit.md finding: chunk position unauthenticated
