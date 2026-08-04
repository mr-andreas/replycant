# 0010 — No webapp identity key expiration

**Status:** Accepted

## Context

The webapp currently creates browser-owned identity material for onboarding:

- an mTLS client certificate/private key pair
- an age key pair used to unwrap repository encryption keys

This identity is persisted in local storage and reused on startup. A 7-day TTL
currently forces expiry, which clears identity state and sends users back to
identity creation.

Forced expiry creates avoidable onboarding churn and key rotation burden for
browser clients. For this product stage, we want stable browser identity
credentials that remain valid unless users explicitly reset setup.

## Decision

1. Remove webapp identity expiration checks from onboarding flow.
2. Remove `expiresAt` from persisted and decrypted identity data models.
3. Remove `isIdentityExpired()` from identity APIs and exports.
4. Keep browser-generated certificates long-lived by setting X.509 `notAfter`
   to 100 years from issuance.

## Consequences

**Positive:**

- Webapp users are not forced through periodic identity recreation.
- Onboarding and unlock flows become deterministic and simpler.
- Local identity records no longer carry expiration-specific fields.

**Negative:**

- Browser identity credentials are effectively indefinite unless users wipe
  local state.
- Rotating compromised or obsolete browser credentials now relies on explicit
  reset/re-provisioning instead of automatic time-based expiry.
