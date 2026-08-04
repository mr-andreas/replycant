# ADR-0012: Identity At-Rest Encryption

## Status
Accepted

## Context
The webapp previously persisted mTLS PEM material and the age private key as
cleartext strings in `localStorage`. An optional PBKDF2 path existed, but the
password field was commented out, so every install stored secrets in the clear.
A localStorage dump, Chromium profile copy, or XSS that read storage yielded
total compromise of device identity and encryption keys.

Users still need a passwordless Electron launch path: requiring a password on
every desktop start is worse UX than the product can accept for the default
case. Plain browser tabs have no OS keyring equivalent.

ADR-0011 still requires extractable PEM material in RAM after unlock so the
local proxy can perform mTLS. Non-extractable `CryptoKey` storage is therefore
out of scope for this decision.

## Decision
Identity secrets are always AES-GCM encrypted before persistence. The wrapping
key source depends on the runtime:

1. **Electron with a strong `safeStorage` backend** (`wrap: "device"`):
   generate a random 32-byte device key, store it in
   `userData/replycant/identityKey.bin` encrypted by Electron `safeStorage`,
   and use that key to wrap the identity payload in `localStorage`. Startup
   unlocks silently with no password UI.
2. **Plain browser, or Electron when only `basic_text` is available**
   (`wrap: "password"`): require a user password, derive the AES key with
   PBKDF2-SHA256 (150k iterations), and prompt on unlock.

`basic_text` is treated as unavailable because it obfuscates with a hardcoded
key rather than an OS keyring. Alpha installs reject v1 / cleartext records and
force re-onboarding; there is no migration path.

Public metadata (`publicKeySsh`, `agePublicKey`, device name/uuid) remains
cleartext so QR authorization and provisioning keep working without unlock.

## Consequences

### Positive
- Disk and Chromium-profile theft no longer yield private keys when the OS
  keyring (or user password) is intact.
- Electron keeps passwordless launch for the common desktop case.
- The Node proxy / ADR-0011 PEM path is unchanged: secrets are still available
  in RAM after unlock.

### Negative
- Post-unlock XSS can still read keys from JavaScript memory. CSP and related
  XSS hardening remain a separate control.
- Linux hosts without a real keyring fall back to passwords instead of silent
  unlock.
- Existing cleartext identities are wiped; users must re-onboard.
