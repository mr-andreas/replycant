# ADR-0005: Dedicated Decrypting Proxy for Encrypted LFS Reads

## Status
Accepted

## Context
Replycant encrypts binary LFS objects client-side with per-object DEKs and chunked AES-256-GCM. The `transcoded` service must read plaintext bytes to support ffmpeg probing and random-access segment generation, but `gitd` must remain keyless.

Embedding decryption logic directly into `transcoded` couples media-transcode concerns with cryptographic range/decryption concerns and makes it harder to reuse decryption behavior for future services that may need plaintext object reads.

## Decision
Introduce a dedicated `decryptd` microservice in the server stack.

- `decryptd` exposes strict `GET /objects/{oid}` reads that require:
  - `X-Replycant-DEK` (base64, 32-byte decoded key)
  - `X-Replycant-Chunk-Size` (positive integer)
- `decryptd` maps plaintext byte ranges to encrypted chunk ranges, fetches encrypted bytes from upstream LFS, decrypts in RAM, and returns plaintext bytes.
- `decryptd` is a trust-boundary exception: it may receive request-scoped DEKs, but never stores key material.
- KEK must never be transmitted to backend services.
- `gitd` remains keyless and unchanged.

## Consequences

### Positive
- Decryption is isolated into a reusable service for any future backend consumer needing plaintext object access.
- `transcoded` keeps focus on media adaptation while relying on plaintext-compatible HTTP reads.
- Trust boundaries are explicit: only `decryptd` handles request-scoped DEKs.

### Negative
- Adds one network hop (`transcoded` -> `decryptd` -> LFS) to encrypted read paths.
- Introduces a new operational service to monitor and test.
- Requires strict header validation and redaction discipline to avoid secret leakage.
