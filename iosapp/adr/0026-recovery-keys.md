# ADR-0026: recovery keys for repository access restoration

## Status

Accepted

## Context

`replycant` authenticates git access with device-bound P-256 client certificates
whose public keys live in `pubkeys/*.pub`. If a user loses every enrolled
device, there is no remaining private key that can authenticate to gitd, so the
repository becomes inaccessible.

The recovery feature must let users recover after uninstall/reinstall while
keeping normal device identity immutable and preserving encrypted content access.

## Decision

Introduce a password-protected recovery bundle created on iOS.

- Recovery pubkeys are committed as:
  - `pubkeys/<label>-<uuid>.recovery.pub`
  - `pubkeys/<label>-<uuid>.recovery.age`
- Bundle payload is JSON, encrypted with `PBKDF2-HMAC-SHA256` + `AES-256-GCM`.
- Bundle plaintext carries:
  - recovery P-256 private key (PEM)
  - recovery age private key
  - discovery URL
  - pinned CA SHA-256 hash
- Share/export uses:
  - raw envelope JSON in QR
  - `replycant://recover?v=1&d=...` deep link in text
- Recovery runs only on fresh installs. Configured devices are rejected and
  guided to reinstall.
- Recovery temporarily authenticates with the recovery P-256 key, clones, adds
  a new device key, re-wraps KEK epochs for the new device age key, then
  restores transport to the normal device identity and deletes temporary
  recovery identity material.

## Consequences

- Users gain a supported path to restore repository access after full key loss.
- Recovery keys are exportable by design, so secrecy depends on the bundle
  password; UX includes strong-password generation and strength guidance.
- The recovery key can be rotated after use by deleting old `.recovery.*` files
  and creating a replacement key.
