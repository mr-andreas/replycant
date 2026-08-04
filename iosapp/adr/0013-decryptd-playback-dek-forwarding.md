# ADR-0013: Decryptd Playback with DEK Forwarding

## Status

Superseded by ADR-0025 for the chunk-size header. DEK forwarding remains in effect.

## Context

ADR-0012 keeps KEK material client-side and treats backend systems as untrusted storage/transcode infrastructure. After introducing the dedicated `decryptd` service on the server side, iOS needs a playback contract that allows server-side transcoding of encrypted LFS objects without sending KEKs to backend services.

Fullscreen video playback currently requests HLS URLs using manifest SHA-256 fields and does not provide decryption metadata required by `decryptd`.

## Decision

iOS fullscreen video playback will:

1. Read the LFS pointer for the selected media object.
2. Load KEK locally for the pointer epoch and unwrap the object DEK locally on-device.
3. Build HLS URLs using the encrypted LFS object OID from the pointer.
4. Send only request-scoped decrypt headers:
   - `X-Replycant-DEK` (base64, 32-byte decoded DEK)
   - `X-Replycant-Chunk-Size` (positive integer)

KEK must never be sent to `transcoded`, `decryptd`, or `gitd`.

## Consequences

### Positive

- Preserves ADR-0012's KEK isolation while enabling encrypted media transcoding.
- Keeps backend key exposure scoped to per-object DEKs and per-request lifetime.
- Aligns iOS playback with the server-side decrypting proxy contract.

### Negative

- Playback path now depends on local pointer parsing and KEK availability before streaming.
- AVPlayer setup is more complex due to custom HLS request headers.
- Debugging playback failures requires checking pointer metadata and header propagation.

## References

- ADR-0012: KEK/DEK Envelope Encryption with age Key Wrapping
- server ADR-0005: Dedicated Decrypting Proxy for Encrypted LFS Reads
