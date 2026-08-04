# ADR-0012: KEK/DEK Envelope Encryption with age Key Wrapping

## Status

Superseded by ADR-0023 for the plaintext migration path. Envelope encryption design remains in effect.

## Context

The git server and LFS server are treated as untrusted storage. They must store only opaque encrypted data so a server compromise does not expose user media or manifest contents.

The existing iOS implementation stores:

- Manifests as plaintext YAML in git
- Binary media as plaintext blobs in LFS (addressed by LFS pointer files)

This does not satisfy encryption-at-rest requirements. We also need a multi-device key distribution model where:

1. Adding a new device does not require re-encrypting all historical objects
2. Removing a device blocks it from future data without expensive full-history rewrite
3. Binary storage supports random access reads for future media workflows

## Decision

Replycant adopts envelope encryption with three layers:

1. **age (X25519) wrapping** distributes a per-epoch KEK to authorized devices
2. **KEK (AES-256)** encrypts manifests and wraps per-object DEKs
3. **DEK (AES-256, per binary object)** encrypts binary content in chunks

### Key distribution model

- Every device has an additional age X25519 keypair (besides the existing P-256 mTLS identity).
- The age private key is stored in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Public age keys are committed in `pubkeys/*.age`.
- Active KEK material is stored by epoch in:
  - `encryption/current`
  - `encryption/epochs/{n}.age`

Each epoch file is age-encrypted for all current device recipients.

### Manifest encryption

Manifest YAML is encrypted directly with the current KEK using AES-256-GCM and stored in this format:

```text
REPLYCANT-ENC-V1
kek-epoch: <n>
---
<12-byte nonce><ciphertext><16-byte tag>
```

The `.yaml` path remains unchanged so repository structure and loaders stay consistent.

### Binary encryption

Each binary object uses a random 32-byte DEK. Content is encrypted chunk-by-chunk (1 MB plaintext chunks) using AES-256-GCM.

- Nonce per chunk is derived from chunk index (12-byte big-endian value).
- Encrypted chunks are concatenated without an additional blob header.
- LFS pointer files carry decryption metadata using custom fields:
  - `x-replycant-kek-epoch`
  - `x-replycant-wrapped-dek`
  - `x-replycant-chunk-size`

### Device lifecycle behavior

- **Add device:** re-wrap existing KEK epoch files to include new recipient; no object re-encryption required.
- **Remove device / rotate forward:** create new KEK epoch and bump `encryption/current`; historical data remains decryptable only with old keys.

## Consequences

### Positive

1. Server-side storage is opaque for both manifests and binaries.
2. Per-object DEKs reduce blast radius compared with a single data key.
3. Adding devices is operationally cheap (re-wrap small KEK files only).
4. Chunk encryption supports future random-access decryption.
5. Existing git/LFS topology is preserved, minimizing migration risk.

### Negative

1. Git diffs for manifests become opaque ciphertext rather than readable YAML.
2. age wire-format support and KEK epoch logic add client complexity.
3. Revoked devices can still decrypt historical data they already had keys for unless history is rewritten.
4. Pointer parsing becomes stricter due to required `x-replycant-*` metadata.

## Alternatives Considered

### 1. Single global key for everything

Use one symmetric key for all manifests and binaries.

**Rejected because:** key compromise exposes the entire corpus and rotation would be expensive.

### 2. Per-manifest DEKs + per-binary DEKs

Use separate DEKs for every file type.

**Rejected because:** manifest count is high and per-file re-wrapping overhead is unnecessary for current requirements.

### 3. SOPS-managed manifest encryption

Store manifests using SOPS + age.

**Rejected because:** native iOS SOPS compatibility introduces substantial additional format complexity for limited near-term benefit.

## Migration Path

**Superseded by ADR-0023.** Clients no longer accept plaintext manifests or
LFS objects. The previous dual-format readers were removed because they
conflicted with the untrusted-server threat model under the alpha
no-backwards-compat policy.

## References

- ADR-0003: Manifest-Based Git Database
- ADR-0009: ECDSA P-256 Client Certificates for mTLS
- ADR-0011: Immutable Device Identity
- https://age-encryption.org/v1
