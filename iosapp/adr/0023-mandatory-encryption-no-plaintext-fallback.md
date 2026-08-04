# ADR-0023: Mandatory Encryption Without Plaintext Fallback

## Status

Accepted (supersedes ADR-0012 Migration Path)

## Context

ADR-0012's Migration Path required clients to accept plaintext manifests when
the `REPLYCANT-ENC-V1` header was absent, and plaintext LFS objects when
`x-replycant-*` pointer metadata was missing. That allowed gradual rollout,
but it also means a hostile or compromised git/LFS server can strip encryption
metadata and have clients render attacker-controlled content.

This product is in alpha with no backwards-compatibility requirement. Existing
installations wipe state and start fresh. Keeping a plaintext fallback conflicts
with the untrusted-server threat model.

## Decision

All clients reject plaintext on every security-relevant read path:

1. **Manifest blobs** lacking the `REPLYCANT-ENC-V1` envelope fail decryption
   instead of being parsed as YAML (iOS `ManifestSyncEngine`, webapp
   `ManifestBlobReader`, Go `git-replycant` smudge filter-process / stdin
   smudge).
2. **LFS media** lacking complete encryption metadata (`kek-epoch`,
   `wrapped-dek`, `chunk-size`, and an unwrapped DEK where applicable) is not
   fetched or rendered as plaintext. Webapp fetchers throw; iOS and Go LFS
   smudge already failed closed.
3. **Decrypted plaintext integrity**: webapp media fetch throws on sha256
   mismatch after decryption instead of warning and continuing.

### Textconv exception

`git-replycant smudge` remains lenient only when invoked as git `textconv`
with a path argument. Git passes already-smudged worktree plaintext for
display in `git diff`. That path never writes to the working tree or a client
database and is not a security bypass for repository objects.

## Consequences

### Positive

- A compromised server cannot strip envelopes or pointer metadata and have
  clients accept attacker content.
- Client behavior matches the stated threat model: storage is opaque ciphertext.
- Alpha no-backwards-compat rule removes the need for dual-format readers.

### Negative

- Test fixtures and importers that wrote plaintext git objects must encrypt
  at write time (or rely on a configured clean filter).
- Incomplete sync state (missing pointers) surfaces as failed media loads
  rather than plaintext fallbacks.

## References

- ADR-0012: KEK/DEK Envelope Encryption with age Key Wrapping
- Alpha Stage: No Backwards Compatibility workspace rule
